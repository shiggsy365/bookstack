import re
from urllib.parse import quote_plus, urljoin

from bs4 import BeautifulSoup
from flask import Blueprint, jsonify, request

from .security import get_with_allowed_redirects

bp = Blueprint('series_order', __name__, url_prefix='/api/bookseriesinorder')
BSIO_HOSTS = {'bookseriesinorder.com', 'www.bookseriesinorder.com'}
BASE_URL = 'https://www.bookseriesinorder.com'


def fetch_soup(url):
    resp = get_with_allowed_redirects(
        url, allowed_hosts=BSIO_HOSTS,
        headers={'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'},
        timeout=120
    )
    resp.raise_for_status()
    return BeautifulSoup(resp.content, 'html.parser')


@bp.route('/search')
def search():
    query = request.args.get('q', '').strip()
    if not query:
        return jsonify([])
    try:
        soup, authors, seen = fetch_soup(f'{BASE_URL}/?s={quote_plus(query)}'), [], set()
        results = soup.find('ul', id='search_result')
        for link in results.find_all('a', href=True, rel='bookmark') if results else []:
            href, name = urljoin(BASE_URL, link.get('href', '')), link.get_text(strip=True)
            if not name or href in seen or not href.startswith(BASE_URL + '/'):
                continue
            seen.add(href)
            authors.append({'name': name, 'url': href, 'description': ''})
        return jsonify(authors[:40])
    except Exception as e:
        return jsonify({'error': f'Connection error: {e}'}), 500


@bp.route('/author')
def author():
    author_url = request.args.get('url', '')
    if not author_url:
        return jsonify({'error': 'No URL provided'}), 400
    try:
        soup = fetch_soup(author_url)
        heading = soup.find('h1', class_='entry-title') or soup.find('h1')
        author_name = heading.get_text(strip=True) if heading else ''
        author_name = re.sub(r'\s+(Book Series in Order|Books in Order|Series in Order|Book Series|Books|Series)\s*$', '', author_name, flags=re.I).strip()
        content = soup.find('div', class_='entry-content') or soup.find('main') or soup.find('article') or soup.find('body')
        if not content:
            return jsonify({'author': author_name, 'series': []})

        series = []
        for heading in content.find_all('h2'):
            match = re.match(r'^Publication Order of\s+(.+)$', heading.get_text(strip=True), flags=re.I)
            if not match:
                continue
            table = None
            for elem in heading.next_elements:
                if getattr(elem, 'name', None) == 'h2':
                    break
                if getattr(elem, 'name', None) == 'table':
                    table = elem
                    break
            if not table:
                continue
            books = []
            for title_cell in table.select('td.booktitle'):
                extra_authors = title_cell.find(class_='extra_authors')
                if extra_authors:
                    extra_authors.extract()
                title = title_cell.get_text(' ', strip=True)
                if title:
                    books.append({'title': title})
            if books:
                series.append({'name': match.group(1), 'books': books})
        return jsonify({'author': author_name, 'series': [item for item in series if item['books']]})
    except Exception as e:
        return jsonify({'error': f'Connection error: {e}'}), 500
