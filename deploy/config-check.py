"""Validate operator settings and optionally DNS; no credentials are read."""
import ipaddress
import os
import re
import socket
import sys

def validate(values):
    shop, pay = values['SHOP_DOMAIN'], values['PAY_DOMAIN']
    for domain in (shop, pay):
        labels = domain.split('.')
        if (len(domain) > 253 or len(labels) < 2 or domain != domain.lower()
                or any(not re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', x) for x in labels)
                or domain == 'example.com' or domain.endswith(('.example.com', '.example', '.invalid'))):
            raise ValueError('Use real lowercase DNS hostnames, without scheme, port or path.')
    if shop == pay:
        raise ValueError('Shop and payment hostnames must differ.')
    address = ipaddress.ip_address(values['SERVER_IPV4'])
    if address.version != 4 or not address.is_global:
        raise ValueError('SERVER_IPV4 must be the actual public IPv4 of your VPS.')
    email = values['ACME_EMAIL']
    if not re.fullmatch(r'[^\s@]+@[^\s@]+\.[^\s@]+', email) or email.endswith('@example.com'):
        raise ValueError('Use your actual certificate contact email.')
    return shop, pay

def main():
    values = {key: os.environ[key] for key in ('SHOP_DOMAIN','PAY_DOMAIN','ACME_EMAIL','SERVER_IPV4')}
    domains = validate(values)
    if '--dns' in sys.argv:
        for domain in domains:
            records = socket.getaddrinfo(domain, 80, type=socket.SOCK_STREAM)
            ipv4 = {r[4][0] for r in records if r[0] == socket.AF_INET}
            ipv6 = {r[4][0] for r in records if r[0] == socket.AF_INET6}
            if ipv4 != {values['SERVER_IPV4']}:
                raise ValueError(f'{domain}: A records do not match SERVER_IPV4. Disable CDN proxy and correct DNS.')
            if ipv6:
                raise ValueError(f'{domain}: AAAA exists. This IPv4 deployment guide requires removing AAAA first.')
            print(f'PASS: {domain} resolves only to the configured public IPv4.')

if __name__ == '__main__':
    try:
        main()
    except (KeyError, ValueError, OSError) as exc:
        raise SystemExit('ERROR: '+str(exc))
