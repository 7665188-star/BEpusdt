#!/usr/bin/env python3
"""Read-only checks; never print credentials, wallet addresses or RPC URLs."""
from contextlib import closing
from pathlib import Path
import hmac
import os
import json
import sqlite3
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import yaml

PAYMENT_ORIGIN = "https://" + os.environ["PAY_DOMAIN"]
SHOP_ORIGIN = "https://" + os.environ["SHOP_DOMAIN"]


def report(label, success):
    print(("PASS: " if success else "FAIL: ") + label, flush=True)
    return bool(success)


def read_configuration(bep_path, mall_root):
    results = []
    with closing(sqlite3.connect(bep_path.resolve().as_uri() + "?mode=ro", uri=True)) as db:
        conf = dict(db.execute("SELECT k,v FROM bep_conf"))
        wallets = db.execute(
            "SELECT COUNT(*) FROM bep_wallet WHERE trade_type='usdt.bep20' AND status=1"
        ).fetchone()[0]
    results.append(report("At least one USDT-BEP20 receiving wallet is enabled", wallets > 0))
    results.append(report("BEpusdt installation lock is set", conf.get("system_install_lock") == "1"))
    results.append(report("BEpusdt application URI matches configured payment domain",
                          conf.get("api_app_uri", "").rstrip("/") == PAYMENT_ORIGIN))

    config = yaml.safe_load((mall_root / "config.yml").read_text(encoding="utf-8"))
    if config["database"]["driver"] != "sqlite":
        raise RuntimeError("Unsupported diagnostic database driver")
    dsn = str(config["database"]["dsn"]).split("?", 1)[0]
    mall_db = Path(dsn)
    if not mall_db.is_absolute():
        mall_db = mall_root / mall_db
    with closing(sqlite3.connect(mall_db.resolve().as_uri() + "?mode=ro", uri=True)) as db:
        rows = db.execute(
            "SELECT config_json,interaction_mode FROM payment_channels "
            "WHERE provider_type='bepusdt' AND is_active=1 AND deleted_at IS NULL"
        ).fetchall()
    candidates = []
    for raw, interaction in rows:
        data = json.loads(raw)
        if data.get("trade_type") == "usdt.bep20" and data.get("order_mode", "transaction") == "transaction":
            candidates.append((data, interaction))
    results.append(report("Exactly one active BEpusdt BEP20 channel is configured", len(candidates) == 1))
    if len(candidates) == 1:
        channel, interaction = candidates[0]
        checks = [
            ("Channel gateway matches configured payment domain", str(channel.get("gateway_url", "")).rstrip("/") == PAYMENT_ORIGIN),
            ("Channel uses CNY pricing", channel.get("fiat", "CNY") == "CNY"),
            ("Channel uses redirect interaction", interaction == "redirect"),
            ("Payment callback URL matches the mall", channel.get("notify_url") == SHOP_ORIGIN + "/api/v1/payments/callback"),
            ("Payment return URL matches the mall", str(channel.get("return_url", "")).rstrip("/") == SHOP_ORIGIN + "/pay"),
            ("API Token matches BEpusdt (value hidden)", bool(conf.get("api_auth_token")) and hmac.compare_digest(
                str(channel.get("auth_token", "")).encode(), conf.get("api_auth_token", "").encode())),
        ]
        results.extend(report(label, success) for label, success in checks)
    return conf.get("rpc_endpoint_bsc", ""), all(results)


class RPCReadError(RuntimeError):
    pass


def request_rpc(endpoint, payload):
    method = payload[0]["method"] if isinstance(payload, list) else payload["method"]
    # Match BEpusdt's Go HTTP client: its explicit Transport has no proxy hook.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    req = urllib.request.Request(endpoint, data=json.dumps(payload).encode(), headers={
        "Content-Type": "application/json", "User-Agent": "Go-http-client/1.1",
    })
    try:
        response = opener.open(req, timeout=15)
    except urllib.error.HTTPError as error:
        raise RPCReadError(method + ": HTTP " + str(error.code)) from None
    with response:
        result = json.load(response)
    items = result if isinstance(result, list) else [result]
    for item in items:
        if not isinstance(item, dict):
            raise RPCReadError(method + ": invalid JSON-RPC response")
        if item.get("error") or "result" not in item:
            error = item.get("error")
            code = error.get("code") if isinstance(error, dict) else None
            suffix = " (code " + str(code) + ")" if isinstance(code, int) else ""
            raise RPCReadError(method + ": JSON-RPC rejected the request" + suffix)
    return result


def call(endpoint, method, params):
    return request_rpc(endpoint, {"jsonrpc": "2.0", "id": 1, "method": method, "params": params})["result"]


def check_rpc(endpoint):
    if not endpoint.startswith("https://"):
        report("A HTTPS BSC RPC endpoint is configured", False)
        return False
    print("INFO: BSC RPC host: " + (urllib.parse.urlsplit(endpoint).hostname or "unknown"), flush=True)
    if not report("RPC chain ID is BSC mainnet (56)", int(call(endpoint, "eth_chainId", []), 16) == 56):
        return False
    height = int(call(endpoint, "eth_blockNumber", []), 16)
    report("BSC block height can be read", height > 1)
    if height <= 1:
        return False
    batch = request_rpc(endpoint, [
        {"jsonrpc": "2.0", "id": index, "method": "eth_getBlockByNumber", "params": [hex(number), True]}
        for index, number in enumerate((height - 1, height), 1)
    ])
    if not isinstance(batch, list) or len(batch) != 2:
        report("RPC supports batched full-block reads", False)
        return False
    blocks = {item.get("id"): item.get("result") for item in batch if not item.get("error")}
    if not report("RPC supports batched full-block reads", all(isinstance(blocks.get(index), dict) for index in (1, 2))):
        return False
    block = blocks[1]
    age = abs(int(time.time()) - int(block["timestamp"], 16))
    fresh = report("Latest BSC block is within 5 minutes of server time", age <= 300)
    logs = call(endpoint, "eth_getLogs", [{
        "fromBlock": hex(height - 1), "toBlock": hex(height - 1),
        "topics": ["0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"],
    }])
    log_ok = report("Transfer event logs can be read", isinstance(logs, list))
    txs = block.get("transactions") or []
    receipt_ok = True
    if txs:
        tx_hash = txs[0]["hash"] if isinstance(txs[0], dict) else txs[0]
        receipt_ok = report("Transaction receipts can be read", isinstance(call(endpoint, "eth_getTransactionReceipt", [tx_hash]), dict))
    else:
        print("INFO: selected block is empty; receipt check skipped.", flush=True)
    return fresh and log_ok and receipt_ok


def main():
    try:
        endpoint, settings_ok = read_configuration(Path("/var/lib/bepusdt/sqlite.db"), Path("/opt/dujiao-next"))
    except Exception as error:
        print("FAIL: local configuration could not be inspected (" + type(error).__name__ + "); private details omitted.")
        return 1
    try:
        node_ok = check_rpc(endpoint)
    except RPCReadError as error:
        print("FAIL: BSC RPC " + str(error) + "; URL and private details omitted.")
        node_ok = False
    except Exception as error:
        print("FAIL: BSC RPC read check failed (" + type(error).__name__ + "); URL and private details omitted.")
        node_ok = False
    if settings_ok and node_ok:
        print("READY: configuration and node checks passed. A real payment/callback test is still required.")
        return 0
    print("NOT READY: resolve the failed checks before making a test payment.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
