from urllib.parse import urljoin, urlparse

import requests


def get_origin(url):
    parsed = urlparse(url)
    port = parsed.port
    if port is None:
        port = 443 if parsed.scheme.lower() == 'https' else 80
    return (parsed.scheme.lower(), parsed.hostname.lower() if parsed.hostname else '', port)


def validate_url(url, allowed_origins=None, allowed_hosts=None):
    parsed = urlparse(url)
    if parsed.scheme not in ('http', 'https') or not parsed.hostname:
        raise ValueError('Only absolute HTTP(S) URLs are allowed')

    hostname = parsed.hostname.lower()
    if allowed_origins and get_origin(url) not in allowed_origins:
        raise ValueError('URL origin is not allowed')
    if allowed_hosts and hostname not in allowed_hosts:
        raise ValueError('URL host is not allowed')
    return url


def get_with_allowed_redirects(url, allowed_origins=None, allowed_hosts=None, **kwargs):
    current_url = validate_url(url, allowed_origins, allowed_hosts)
    for _ in range(6):
        resp = requests.get(current_url, allow_redirects=False, **kwargs)
        if not resp.is_redirect:
            return resp
        location = resp.headers.get('Location')
        if not location:
            return resp
        current_url = validate_url(urljoin(current_url, location), allowed_origins, allowed_hosts)
    raise requests.exceptions.TooManyRedirects('Too many redirects')
