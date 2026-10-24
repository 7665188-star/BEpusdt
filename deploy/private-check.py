from contextlib import closing
import json
import sqlite3
import sys
import time
import urllib.request

def main():
    domain = sys.argv[1]
    with closing(sqlite3.connect('file:/var/lib/bepusdt/sqlite.db?mode=ro', uri=True)) as db:
        settings = dict(db.execute('SELECT k,v FROM bep_conf'))
    if settings.get('system_install_lock') != '1' or settings.get('api_app_uri') != 'https://'+domain:
        raise SystemExit('Installation lock or payment application URI is incorrect.')
    public = '--public' in sys.argv
    require_notice = '--require-notice' in sys.argv
    origin = 'https://'+domain if public else 'http://127.0.0.1:8082'
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    for attempt in range(30):
        try:
            with opener.open(origin+'/', timeout=5) as response:
                body = response.read(1024*1024).decode('utf-8', errors='replace')
                if response.status != 200 or response.headers.get('Payment-Gateway') != 'https://github.com/v03413/BEpusdt':
                    raise ValueError('Unexpected payment gateway response.')
            if any(x in body for x in ('id="password"','id="token"','首次运行检测')):
                raise SystemExit('Initial credentials page is still active; payment site must remain private.')
            with opener.open(origin+'/checkout/official/assets/locales/zh.json', timeout=5) as response:
                locale = json.load(response)
            if not isinstance(locale, dict) or not all(isinstance(locale.get(key), str) and locale[key] for key in ('pageTitle', 'feeNotice')):
                raise SystemExit('Official checkout assets are missing or invalid.')
            if require_notice and locale.get('transferFeeWarningTitle') != '重要：付款前请确认手续费':
                raise SystemExit('The optional notice patch is missing.')
            break
        except (OSError, ValueError):
            if attempt == 29:
                raise SystemExit('Gateway or checkout verification failed. No private details printed.')
            time.sleep(1)
    print('PASS: '+('public HTTPS' if public else 'local')+' gateway, initialization lock and checkout assets verified.')
    if require_notice:
        print('PASS: optional notice patch verified.')

if __name__ == '__main__':
    main()
