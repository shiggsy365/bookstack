import random
import re
import time
from datetime import date, timedelta
from urllib.parse import urljoin

import requests
from flask import Blueprint, jsonify, request

from .cache import cached_load
from .config import GOOGLE_BOOKS_API_KEY, HARDCOVER_API_KEY, NYT_BOOKS_API_KEY, OPENLIBRARY_CONTACT
from .providers import clean_html, first_value, normalize_google_books, normalize_openlibrary_books
from .security import get_origin, get_with_allowed_redirects, request_with_retries

bp = Blueprint('discovery', __name__, url_prefix='/api/discovery')

OPENLIBRARY_BASE_URL = 'https://openlibrary.org'
OPENLIBRARY_ORIGINS = {get_origin(OPENLIBRARY_BASE_URL)}
GOOGLE_BOOKS_BASE_URL = 'https://www.googleapis.com'
GOOGLE_BOOKS_ORIGINS = {get_origin(GOOGLE_BOOKS_BASE_URL)}
NYT_BOOKS_BASE_URL = 'https://api.nytimes.com'
NYT_BOOKS_ORIGINS = {get_origin(NYT_BOOKS_BASE_URL)}
HARDCOVER_BASE_URL = 'https://api.hardcover.app'
DISCOVERY_CACHE_SECONDS = 60 * 60
NEW_RELEASES_CACHE_SECONDS = 6 * 60 * 60
BESTSELLERS_CACHE_SECONDS = 24 * 60 * 60
HARDCOVER_CACHE_SECONDS = 6 * 60 * 60
GOOGLE_BOOK_SEARCH_CACHE_SECONDS = 24 * 60 * 60
NYT_WEEK_HISTORY_LIMIT = 26
RECENT_DISCOVERY_YEARS = 4
NEW_RELEASE_YEARS = 2
OPENLIBRARY_SEARCH_FIELDS = 'key,title,author_name,author_key,isbn,cover_i,first_publish_year,subject'
DISCOVERY_CATEGORIES = {
    'science_fiction': 'Science Fiction',
    'fantasy': 'Fantasy',
    'mystery_and_detective_stories': 'Mystery',
    'romance': 'Romance',
    'thriller': 'Thriller',
    'historical_fiction': 'Historical Fiction',
    'biography': 'Biography',
    'history': 'History',
    'young_adult': 'Young Adult',
    'horror': 'Horror'
}
DISCOVERY_COLLECTIONS = {
    'open_library_staff_picks': 'Open Library Staff Picks',
    'classics': 'Classics',
    'historical_fiction': 'Historical Fiction',
    'adventure': 'Adventure Stories'
}
NYT_FALLBACK_BESTSELLER_LISTS = {
    'hardcover-fiction': 'Hardcover Fiction',
    'hardcover-nonfiction': 'Hardcover Nonfiction',
    'combined-print-and-e-book-fiction': 'Combined Fiction',
    'combined-print-and-e-book-nonfiction': 'Combined Nonfiction',
    'young-adult-hardcover': 'Young Adult Hardcover',
    'childrens-middle-grade-hardcover': 'Children Middle Grade'
}
HARDCOVER_TRENDING_PERIODS = {
    'now': {'title': 'Now', 'days': 30},
    '3m': {'title': 'Past 3 Months', 'days': 90},
    '12m': {'title': 'Past 12 Months', 'days': 365},
    'all': {'title': 'All Time', 'days': None}
}
HARDCOVER_FALLBACK_GENRES = [
    'Fantasy', 'Science Fiction', 'Romance', 'Mystery', 'Thriller', 'Horror',
    'Historical Fiction', 'Young Adult', 'Biography', 'History', 'Nonfiction'
]
HARDCOVER_BOOKS_QUERY = '''
query BookstackHardcoverBooks($where: books_bool_exp!, $order: [books_order_by!], $limit: Int!) {
  books(where: $where, order_by: $order, limit: $limit) {
    id
    title
    description
    release_date
    release_year
    users_count
    ratings_count
    cached_image
    image {
      url
    }
    contributions(limit: 5) {
      author {
        name
      }
    }
    default_ebook_edition {
      isbn_13
      isbn_10
    }
    default_physical_edition {
      isbn_13
      isbn_10
    }
    taggings(limit: 20) {
      tag {
        tag
        tag_category {
          category
        }
      }
    }
  }
}
'''
HARDCOVER_GENRES_QUERY = '''
query BookstackHardcoverGenres {
  books(order_by: [{users_count: desc}], limit: 250) {
    taggings(limit: 20) {
      tag {
        tag
        tag_category {
          category
        }
      }
    }
  }
}
'''
HARDCOVER_TRENDING_QUERY = '''
query BookstackTrending($from: date!, $to: date!, $limit: Int!, $offset: Int!) {
  books_trending(from: $from, to: $to, limit: $limit, offset: $offset) {
    ids
    error
  }
}
'''
HARDCOVER_AUTHORS_QUERY = '''
query BookstackAuthorSearch($where: authors_bool_exp!, $limit: Int!) {
  authors(where: $where, order_by: [{users_count: desc}], limit: $limit) {
    id
    name
    bio
    books_count
    cached_image
    image { url }
  }
}
'''




def recent_year(years):
    return date.today().year - years


def published_since(books, since_year, limit=40):
    recent_books = []
    for book in books:
        match = re.match(r'\d{4}', str(book.get('published_year', '')))
        if match and int(match.group(0)) >= since_year:
            recent_books.append(book)
    return recent_books[:limit]


def openlibrary_headers():
    user_agent = 'Bookstack Kindle Browser'
    if OPENLIBRARY_CONTACT:
        user_agent += f' ({OPENLIBRARY_CONTACT})'
    return {'User-Agent': user_agent, 'Accept': 'application/json'}


def hardcover_headers():
    return {
        'User-Agent': 'Bookstack Kindle Browser',
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        'authorization': HARDCOVER_API_KEY.strip()
    }


def get_cached_json(cache_key, url, allowed_origins, headers=None, params=None,
                    cache_seconds=DISCOVERY_CACHE_SECONDS, timeout=30):
    provider = cache_key.split(":", 1)[0]

    def load():
        resp = get_with_allowed_redirects(
            url, allowed_origins=allowed_origins, headers=headers, params=params, timeout=timeout
        )
        resp.raise_for_status()
        return resp.json()

    return cached_load(
        f"json:{cache_key}", provider, cache_seconds, load,
        stale_ttl=max(cache_seconds, 24 * 60 * 60), lock_seconds=timeout + 5
    )


def get_cached_hardcover_graphql(cache_key, query, variables=None, cache_seconds=HARDCOVER_CACHE_SECONDS):
    def load():
        resp = request_with_retries(
            "POST", urljoin(HARDCOVER_BASE_URL, "/v1/graphql"),
            headers=hardcover_headers(), json={"query": query, "variables": variables or {}}, timeout=30
        )
        resp.raise_for_status()
        payload = resp.json()
        if payload.get("errors"):
            message = payload["errors"][0].get("message", "Hardcover GraphQL error")
            raise RuntimeError(message)
        return payload.get("data") or {}

    return cached_load(
        f"graphql:{cache_key}", "hardcover", cache_seconds, load,
        stale_ttl=max(cache_seconds, 24 * 60 * 60), lock_seconds=35
    )


def get_cached_openlibrary_json(cache_key, path, params=None):
    return get_cached_json(
        cache_key, urljoin(OPENLIBRARY_BASE_URL, path), OPENLIBRARY_ORIGINS,
        headers=openlibrary_headers(), params=params
    )


def hardcover_image_url(image):
    if isinstance(image, dict) and image.get('url'):
        return image.get('url')
    if isinstance(image, list):
        image = first_value(image, {})
    if isinstance(image, dict):
        return image.get('url') or image.get('large_url') or image.get('medium_url') or image.get('small_url') or ''
    if isinstance(image, str):
        return image
    return ''


def hardcover_book_authors(book):
    authors, seen = [], set()
    for contribution in book.get('contributions') or []:
        author = contribution.get('author') or {}
        name = author.get('name', '').strip()
        if name and name.lower() not in seen:
            authors.append(name)
            seen.add(name.lower())
    return authors


def hardcover_book_isbn(book):
    for edition_key in ('default_ebook_edition', 'default_physical_edition'):
        edition = book.get(edition_key) or {}
        for key in ('isbn_13', 'isbn_10'):
            if edition.get(key):
                return edition[key]
    return ''


def hardcover_book_genres(book):
    genres, seen = [], set()
    for tagging in book.get('taggings') or []:
        tag = tagging.get('tag') or {}
        category = (tag.get('tag_category') or {}).get('category', '')
        name = tag.get('tag', '').strip()
        if category == 'Genre' and name and name.lower() not in seen:
            genres.append(name)
            seen.add(name.lower())
    return genres


def normalize_hardcover_books(books):
    normalized, seen = [], set()
    for book in books:
        genres = hardcover_book_genres(book)
        authors = hardcover_book_authors(book)
        isbn = hardcover_book_isbn(book)
        title = book.get('title', 'Unknown Title')
        identity = book.get('id') or isbn or (title.lower(), first_value(authors, '').lower())
        if title and identity not in seen:
            published = book.get('release_year') or ''
            if not published and book.get('release_date'):
                published = str(book['release_date'])[:4]
            normalized.append({
                'source': 'hardcover', 'source_id': str(book.get('id') or ''),
                'title': title, 'authors': authors, 'author': first_value(authors, ''),
                'isbn': isbn, 'cover_url': hardcover_image_url(book.get('cached_image')) or hardcover_image_url(book.get('image')),
                'description': clean_html(book.get('description', '')),
                'published_year': published, 'genres': genres,
                'users_count': book.get('users_count') or 0,
                'ratings_count': book.get('ratings_count') or 0,
                'in_library': None, 'library_download_url': None
            })
            seen.add(identity)
    return normalized[:40]


def normalize_nyt_books(books):
    normalized, seen = [], set()
    for book in books:
        isbn = book.get('primary_isbn13') or book.get('primary_isbn10') or ''
        title, author = book.get('title', 'Unknown Title'), book.get('author', '')
        identity = isbn or (title.lower(), author.lower())
        if identity in seen:
            continue
        normalized.append({
            'source': 'nytimes', 'source_id': isbn or title, 'title': title,
            'authors': [author] if author else [], 'author': author, 'isbn': isbn,
            'cover_url': book.get('book_image', ''), 'description': clean_html(book.get('description', '')),
            'published_year': '', 'rank': book.get('rank'), 'weeks_on_list': book.get('weeks_on_list'),
            'in_library': None, 'library_download_url': None
        })
        seen.add(identity)
    return sorted(normalized, key=lambda book: book.get('rank') or 9999)


def extract_nyt_books(data):
    results = data.get('results', {})
    if isinstance(results, dict):
        return results.get('books', [])

    books = []
    for item in results:
        details = first_value(item.get('book_details'), {}) or {}
        if details:
            book = dict(details)
            for key in ('rank', 'rank_last_week', 'weeks_on_list'):
                book[key] = item.get(key)
            books.append(book)
    return books


def get_nyt_weekly_lists():
    data = get_cached_json(
        'nytimes:bestseller-lists', urljoin(NYT_BOOKS_BASE_URL, '/svc/books/v3/lists/names.json'),
        NYT_BOOKS_ORIGINS, headers={'User-Agent': 'Bookstack Kindle Browser'},
        params={'api-key': NYT_BOOKS_API_KEY}, cache_seconds=BESTSELLERS_CACHE_SECONDS
    )
    weekly_lists = []
    for item in data.get('results', []):
        slug = item.get('list_name_encoded', '')
        title = item.get('display_name') or item.get('list_name') or slug
        newest_date = item.get('newest_published_date', '')
        if slug and item.get('updated') == 'WEEKLY' and newest_date:
            weekly_lists.append({
                'slug': slug, 'title': title,
                'newest_published_date': newest_date,
                'oldest_published_date': item.get('oldest_published_date', '')
            })
    if not weekly_lists:
        return []

    latest_date = max(item['newest_published_date'] for item in weekly_lists)
    active_since = date.fromisoformat(latest_date) - timedelta(days=14)
    return [
        item for item in weekly_lists
        if date.fromisoformat(item['newest_published_date']) >= active_since
    ]


def get_nyt_bestseller_lists():
    if not NYT_BOOKS_API_KEY:
        return []
    try:
        weekly_lists = get_nyt_weekly_lists()
        if weekly_lists:
            return weekly_lists
    except Exception as e:
        print(f'[ERROR] NYT bestseller list catalog failed: {type(e).__name__}', flush=True)
    return [
        {'slug': slug, 'title': title}
        for slug, title in NYT_FALLBACK_BESTSELLER_LISTS.items()
    ]


def get_nyt_bestseller_list(slug):
    return next((item for item in get_nyt_bestseller_lists() if item['slug'] == slug), None)


def get_nyt_bestseller_weeks(list_info):
    if list_info.get('newest_published_date'):
        newest_date = date.fromisoformat(list_info['newest_published_date'])
        oldest_date = date.fromisoformat(list_info.get('oldest_published_date') or list_info['newest_published_date'])
    else:
        today = date.today()
        newest_date = today - timedelta(days=(today.weekday() + 1) % 7)
        oldest_date = newest_date - timedelta(days=7 * (NYT_WEEK_HISTORY_LIMIT - 1))
    weeks = []
    published_date = newest_date
    while published_date >= oldest_date and len(weeks) < NYT_WEEK_HISTORY_LIMIT:
        weeks.append({'date': published_date.isoformat(), 'title': published_date.strftime('%d %b %Y')})
        published_date -= timedelta(days=7)
    return weeks


def openlibrary_search(cache_key, query, sort='trending'):
    params = {'q': query, 'fields': OPENLIBRARY_SEARCH_FIELDS, 'limit': 40}
    if sort and sort != 'relevance':
        params['sort'] = sort
    data = get_cached_openlibrary_json(cache_key, '/search.json', params)
    return normalize_openlibrary_books(data.get('docs', []))


def get_hardcover_genres():
    if not HARDCOVER_API_KEY:
        return []
    try:
        data = get_cached_hardcover_graphql('hardcover:genres', HARDCOVER_GENRES_QUERY)
        counts = {}
        for book in data.get('books', []):
            for genre in hardcover_book_genres(book):
                counts[genre] = counts.get(genre, 0) + 1
        if counts:
            return [genre for genre, _count in sorted(counts.items(), key=lambda item: (-item[1], item[0].lower()))[:50]]
    except Exception as e:
        print(f'[ERROR] Hardcover genres failed: {type(e).__name__}', flush=True)
    return HARDCOVER_FALLBACK_GENRES


def hardcover_published_where(days=None, future=False):
    today = date.today()
    op = '_gte' if future else '_lte'
    where = {'release_date': {op: today.isoformat()}}
    if days:
        where['release_date']['_gte'] = (today - timedelta(days=days)).isoformat()
    return where


def hardcover_books(cache_key, where, order, genre=''):
    if genre:
        where = dict(where)
        where['taggings'] = {'tag': {'tag': {'_eq': genre}, 'tag_category': {'category': {'_eq': 'Genre'}}}}
    data = get_cached_hardcover_graphql(
        cache_key, HARDCOVER_BOOKS_QUERY,
        {'where': where, 'order': order, 'limit': 40}
    )
    return normalize_hardcover_books(data.get('books', []))


@bp.route('/hardcover-genres')
def hardcover_genres():
    return jsonify({'enabled': bool(HARDCOVER_API_KEY), 'genres': get_hardcover_genres()})


@bp.route('/hardcover-trending')
def hardcover_trending():
    period = request.args.get('period', 'now')
    genre = request.args.get('genre', '').strip()
    if not HARDCOVER_API_KEY:
        return jsonify({'error': 'Hardcover API key is not configured'}), 503
    if period not in HARDCOVER_TRENDING_PERIODS:
        return jsonify({'error': 'Invalid trending period'}), 400

    period_info = HARDCOVER_TRENDING_PERIODS[period]
    try:
        books = hardcover_books(
            f'hardcover:trending:{period}:{genre.lower()}',
            hardcover_published_where(days=period_info['days']),
            [{'users_count': 'desc'}, {'ratings_count': 'desc'}],
            genre=genre
        )
        title = f"Trending - {period_info['title']}"
        if genre:
            title += f' - {genre}'
        return jsonify({'title': title, 'books': books})
    except Exception as e:
        print(f'[ERROR] Hardcover trending failed: {type(e).__name__}', flush=True)
        return jsonify({'error': 'Unable to load Hardcover trending books'}), 502


@bp.route('/hardcover-new-releases')
def hardcover_new_releases():
    genre = request.args.get('genre', '').strip()
    if not HARDCOVER_API_KEY:
        return jsonify({'error': 'Hardcover API key is not configured'}), 503

    try:
        books = hardcover_books(
            f'hardcover:new-releases:{genre.lower()}',
            hardcover_published_where(days=120),
            [{'release_date': 'desc'}, {'users_count': 'desc'}],
            genre=genre
        )
        title = 'New Releases'
        if genre:
            title += f' - {genre}'
        return jsonify({'title': title, 'books': books})
    except Exception as e:
        print(f'[ERROR] Hardcover new releases failed: {type(e).__name__}', flush=True)
        return jsonify({'error': 'Unable to load Hardcover new releases'}), 502


@bp.route('/categories')
def categories():
    return jsonify([{'slug': slug, 'title': title} for slug, title in DISCOVERY_CATEGORIES.items()])


@bp.route('/collections')
def collections():
    return jsonify([{'slug': slug, 'title': title} for slug, title in DISCOVERY_COLLECTIONS.items()])


@bp.route('/trending')
def trending():
    period = request.args.get('period', 'daily')
    if period not in ('daily', 'weekly', 'monthly'):
        return jsonify({'error': 'Invalid trending period'}), 400
    try:
        since_year = recent_year(RECENT_DISCOVERY_YEARS)
        data = get_cached_openlibrary_json(f'trending:{period}:recent', f'/trending/{period}.json', {'limit': 200})
        return jsonify(published_since(normalize_openlibrary_books(data.get('works', [])), since_year))
    except Exception as e:
        print(f'[ERROR] Open Library trending failed: {type(e).__name__}', flush=True)
        return jsonify({'error': 'Unable to load trending books'}), 502


@bp.route('/category')
def category():
    slug = request.args.get('slug', '')
    if slug not in DISCOVERY_CATEGORIES:
        return jsonify({'error': 'Invalid category'}), 400
    try:
        since_year = recent_year(RECENT_DISCOVERY_YEARS)
        query = f'subject_key:"{slug}" first_publish_year:[{since_year} TO *]'
        return jsonify({'title': DISCOVERY_CATEGORIES[slug], 'books': openlibrary_search(f'category:{slug}:recent', query, sort='readinglog')})
    except Exception as e:
        print(f'[ERROR] Open Library category failed: {type(e).__name__}', flush=True)
        return jsonify({'error': 'Unable to load category'}), 502


@bp.route('/collection')
def collection():
    slug = request.args.get('slug', '')
    if slug not in DISCOVERY_COLLECTIONS:
        return jsonify({'error': 'Invalid collection'}), 400
    try:
        query = f'subject_key:"{slug}"'
        if slug != 'classics':
            query += f' first_publish_year:[{recent_year(RECENT_DISCOVERY_YEARS)} TO *]'
        return jsonify({'title': DISCOVERY_COLLECTIONS[slug], 'books': openlibrary_search(f'collection:{slug}:recent', query, sort='readinglog')})
    except Exception as e:
        print(f'[ERROR] Open Library collection failed: {type(e).__name__}', flush=True)
        return jsonify({'error': 'Unable to load collection'}), 502


@bp.route('/search')
def search():
    query = request.args.get('q', '').strip()
    audience = request.args.get('audience', 'all')
    category_slug = request.args.get('category', '')
    year = request.args.get('year', '').strip()
    if not query:
        return jsonify({'error': 'No query provided'}), 400
    if audience not in ('all', 'fiction', 'nonfiction'):
        return jsonify({'error': 'Invalid audience filter'}), 400
    if category_slug and category_slug not in DISCOVERY_CATEGORIES:
        return jsonify({'error': 'Invalid category filter'}), 400
    if year and (not year.isdigit() or len(year) != 4):
        return jsonify({'error': 'Invalid year filter'}), 400

    terms = [query]
    if audience != 'all':
        terms.append(f'subject_key:"{audience}"')
    if category_slug:
        terms.append(f'subject_key:"{category_slug}"')
    if year:
        terms.append(f'first_publish_year:[{year} TO *]')
    search_query = ' '.join(terms)
    try:
        books = openlibrary_search(f'search:{search_query}', search_query, sort='relevance')
        return jsonify(books)
    except Exception as e:
        print(f'[ERROR] Open Library search failed: {type(e).__name__}', flush=True)
        return jsonify({'error': 'Unable to search books'}), 502


STORE_PUBLICATION_PERIODS = {'any': None, '1y': 1, '3y': 3, '10y': 10}


def store_year_query(period):
    years = STORE_PUBLICATION_PERIODS.get(period)
    since_year = date.today().year - years + 1 if years else None
    return f' first_publish_year:[{since_year} TO *]' if since_year else ''


def hardcover_store_where(period, extra=None):
    where = dict(extra or {})
    today = date.today()
    release_date = {'_lte': today.isoformat()}
    years = STORE_PUBLICATION_PERIODS.get(period)
    if years:
        release_date['_gte'] = date(today.year - years + 1, 1, 1).isoformat()
    where['release_date'] = release_date
    return where


def subject_slug(genre):
    return re.sub(r'[^a-z0-9]+', '_', (genre or '').strip().lower()).strip('_')


@bp.route('/store-trending')
def store_trending():
    period, genre = request.args.get('period', 'all'), request.args.get('genre', '').strip()
    if period not in ('all', '1y', '3y', '10y'):
        return jsonify({'error': 'Invalid publication period'}), 400
    if not HARDCOVER_API_KEY:
        return jsonify({'error': 'Hardcover API key is not configured'}), 503
    try:
        today = date.today()
        variables = {
            'from': (today - timedelta(days=30)).isoformat(),
            'to': today.isoformat(),
            'limit': 100,
            'offset': 0
        }
        data = get_cached_hardcover_graphql(
            'store:hardcover-trending:30d', HARDCOVER_TRENDING_QUERY,
            variables, cache_seconds=HARDCOVER_CACHE_SECONDS
        )
        trending = data.get('books_trending') or {}
        ids = trending.get('ids') or []
        if not ids:
            raise RuntimeError(trending.get('error') or 'No trending books returned')
        books = hardcover_books(
            f'store:hardcover-trending-books:{period}:{genre.casefold()}',
            hardcover_store_where(period, {'id': {'_in': ids}}),
            [{'users_count': 'desc'}], genre=genre
        )
        order = {str(book_id): index for index, book_id in enumerate(ids)}
        books.sort(key=lambda book: order.get(str(book.get('source_id')), len(ids)))
        labels = {'all': 'All Time', '1y': 'Published This Year', '3y': 'Past 3 Years', '10y': 'Past 10 Years'}
        return jsonify({'title': f"Trending - {labels[period]}", 'books': books})
    except Exception as e:
        print(f'[ERROR] Hardcover Store trending failed: {type(e).__name__}', flush=True)
        return jsonify({'error': 'Unable to load Hardcover trending books'}), 502


@bp.route('/store-popular')
def store_popular():
    period, genre = request.args.get('period', 'all'), request.args.get('genre', '').strip()
    if period not in ('all', '1y', '3y', '10y'):
        return jsonify({'error': 'Invalid publication period'}), 400
    if not HARDCOVER_API_KEY:
        return jsonify({'error': 'Hardcover API key is not configured'}), 503
    try:
        books = hardcover_books(
            f'store:popular:{period}:{genre.casefold()}',
            hardcover_store_where(period),
            [{'users_count': 'desc'}, {'ratings_count': 'desc'}], genre=genre
        )
        return jsonify({'title': 'Popular Books', 'books': books})
    except Exception as e:
        print(f'[ERROR] Store popular failed: {type(e).__name__}', flush=True)
        return jsonify({'error': 'Unable to load popular books'}), 502


@bp.route('/store-author-search')
def store_author_search():
    query = request.args.get('q', '').strip()
    if not query:
        return jsonify({'error': 'No author query provided'}), 400
    if not HARDCOVER_API_KEY:
        return jsonify({'error': 'Hardcover API key is not configured'}), 503
    try:
        data = get_cached_hardcover_graphql(
            f'store:hardcover-authors:{query.casefold()}', HARDCOVER_AUTHORS_QUERY,
            {'where': {'name': {'_ilike': f'%{query}%'}}, 'limit': 24}
        )
        authors = []
        for author in data.get('authors') or []:
            authors.append({
                'name': author.get('name') or 'Unknown author',
                'key': f"hc:{author.get('id')}",
                'work_count': author.get('books_count') or 0,
                'bio': author.get('bio') or '',
                'image_url': hardcover_image_url(author.get('image') or author.get('cached_image'))
            })
        return jsonify({'authors': authors})
    except Exception as e:
        print(f'[ERROR] Store author search failed: {type(e).__name__}', flush=True)
        return jsonify({'error': 'Unable to search authors'}), 502


@bp.route('/store-author-books')
def store_author_books():
    key = request.args.get('key', '').strip().replace('/authors/', '')
    genre, period = request.args.get('genre', '').strip(), request.args.get('period', 'any')
    if not key or not re.fullmatch(r'(?:OL\d+A|hc:\d+)', key):
        return jsonify({'error': 'Invalid author key'}), 400
    if period not in STORE_PUBLICATION_PERIODS:
        return jsonify({'error': 'Invalid publication period'}), 400
    if key.startswith('hc:'):
        if not HARDCOVER_API_KEY:
            return jsonify({'error': 'Hardcover API key is not configured'}), 503
        try:
            author_id = int(key.split(':', 1)[1])
            books = hardcover_books(
                f'store:hardcover-author-books:{author_id}:{period}:{genre.casefold()}',
                hardcover_store_where(period, {'contributions': {'author_id': {'_eq': author_id}}}),
                [{'users_count': 'desc'}, {'ratings_count': 'desc'}], genre=genre
            )
            return jsonify({'books': books})
        except Exception as e:
            print(f'[ERROR] Hardcover author books failed: {type(e).__name__}', flush=True)
            return jsonify({'error': 'Unable to load author books'}), 502
    query = f'author_key:{key}'
    if genre:
        query += f' subject_key:"{subject_slug(genre)}"'
    query += store_year_query(period)
    try:
        return jsonify({'books': openlibrary_search(f'store:author-books:{query}', query, sort='readinglog')})
    except Exception as e:
        print(f'[ERROR] Store author books failed: {type(e).__name__}', flush=True)
        return jsonify({'error': 'Unable to load author books'}), 502


@bp.route('/store-book-search')
def store_book_search():
    query = request.args.get('q', '').strip()
    genre, period = request.args.get('genre', '').strip(), request.args.get('period', 'any')
    provider = request.args.get('provider', 'hardcover').strip().lower()
    if not query:
        return jsonify({'error': 'No book query provided'}), 400
    if period not in STORE_PUBLICATION_PERIODS:
        return jsonify({'error': 'Invalid publication period'}), 400
    if provider not in ('hardcover', 'google'):
        return jsonify({'error': 'Invalid search provider'}), 400

    if provider == 'google':
        if not GOOGLE_BOOKS_API_KEY:
            return jsonify({'error': 'Google Books API key is not configured'}), 503
        try:
            google_query = query
            if genre:
                google_query += f' subject:"{genre}"'
            params = {
                'q': google_query, 'orderBy': 'relevance', 'maxResults': 40,
                'printType': 'books', 'key': GOOGLE_BOOKS_API_KEY
            }
            data = get_cached_json(
                f'googlebooks:store-search:{google_query.casefold()}',
                urljoin(GOOGLE_BOOKS_BASE_URL, '/books/v1/volumes'),
                GOOGLE_BOOKS_ORIGINS,
                headers={'User-Agent': 'Bookstack Kindle Browser'}, params=params,
                cache_seconds=GOOGLE_BOOK_SEARCH_CACHE_SECONDS
            )
            books = normalize_google_books(data.get('items') or [])
            years = STORE_PUBLICATION_PERIODS.get(period)
            if years:
                since_year = date.today().year - years + 1
                books = [book for book in books if str(book.get('published_year') or '').isdigit() and int(book['published_year']) >= since_year]
            return jsonify({'title': 'Google Books Results', 'books': books, 'provider': 'google'})
        except Exception as e:
            print('[ERROR] Google Books Store search failed', flush=True)
            return jsonify({'error': 'Unable to search Google Books'}), 502

    if not HARDCOVER_API_KEY:
        return jsonify({'error': 'Hardcover API key is not configured'}), 503
    try:
        books = hardcover_books(
            f'store:hardcover-book-search:{query.casefold()}:{period}:{genre.casefold()}',
            hardcover_store_where(period, {'title': {'_ilike': f'%{query}%'}}),
            [{'users_count': 'desc'}, {'ratings_count': 'desc'}], genre=genre
        )
        return jsonify({'title': 'Hardcover Results', 'books': books, 'provider': 'hardcover'})
    except Exception as e:
        print(f'[ERROR] Store book search failed: {type(e).__name__}', flush=True)
        return jsonify({'error': 'Unable to search books'}), 502


@bp.route('/surprise')
def surprise():
    try:
        period = random.choice(('daily', 'weekly', 'monthly'))
        since_year = recent_year(RECENT_DISCOVERY_YEARS)
        data = get_cached_openlibrary_json(f'trending:{period}:recent', f'/trending/{period}.json', {'limit': 200})
        books = published_since(normalize_openlibrary_books(data.get('works', [])), since_year)
        return jsonify(random.choice(books)) if books else (jsonify({'error': 'No surprise books available'}), 502)
    except Exception as e:
        print(f'[ERROR] Open Library surprise failed: {type(e).__name__}', flush=True)
        return jsonify({'error': 'Unable to find a surprise book'}), 502


@bp.route('/new-releases')
def new_releases():
    since_year = recent_year(NEW_RELEASE_YEARS)
    if not GOOGLE_BOOKS_API_KEY:
        try:
            query = f'subject_key:"fiction" first_publish_year:[{since_year} TO *]'
            return jsonify(openlibrary_search('openlibrary:new-releases:recent', query, sort='new'))
        except Exception as e:
            print(f'[ERROR] Open Library new releases failed: {type(e).__name__}', flush=True)
            return jsonify({'error': 'Unable to load new releases'}), 502
    try:
        data = get_cached_json(
            'googlebooks:new-releases', urljoin(GOOGLE_BOOKS_BASE_URL, '/books/v1/volumes'),
            GOOGLE_BOOKS_ORIGINS, headers={'User-Agent': 'Bookstack Kindle Browser'},
            params={'q': 'subject:fiction', 'orderBy': 'newest', 'maxResults': 40, 'printType': 'books', 'key': GOOGLE_BOOKS_API_KEY},
            cache_seconds=NEW_RELEASES_CACHE_SECONDS
        )
        return jsonify(published_since(normalize_google_books(data.get('items', [])), since_year))
    except Exception as e:
        print(f'[ERROR] Google Books new releases failed: {type(e).__name__}', flush=True)
        return jsonify({'error': 'Unable to load new releases'}), 502


def openlibrary_work_description(source_id):
    if not re.fullmatch(r'/works/OL[0-9]+W', source_id or ''):
        return ''
    data = get_cached_openlibrary_json(f'work:{source_id}', f'{source_id}.json')
    description = data.get('description', '')
    if isinstance(description, dict):
        description = description.get('value', '')
    return clean_html(description)


@bp.route('/details')
def details():
    source, source_id = request.args.get('source', ''), request.args.get('source_id', '')
    if source != 'openlibrary' or not re.fullmatch(r'/works/OL\d+W', source_id):
        return jsonify({'description': ''})
    try:
        data = get_cached_openlibrary_json(f'work:{source_id}', f'{source_id}.json')
        description = data.get('description', '')
        if isinstance(description, dict):
            description = description.get('value', '')
        return jsonify({'description': clean_html(description)})
    except Exception as e:
        print(f'[ERROR] Open Library details failed: {type(e).__name__}', flush=True)
        return jsonify({'description': ''})


@bp.route('/bestseller-lists')
def bestseller_lists():
    return jsonify({'enabled': bool(NYT_BOOKS_API_KEY), 'lists': get_nyt_bestseller_lists()})


@bp.route('/bestsellers')
def bestsellers():
    slug = request.args.get('slug', '')
    published_date = request.args.get('date', 'current')
    if not NYT_BOOKS_API_KEY:
        return jsonify({'error': 'NYT Books API key is not configured'}), 503
    list_info = get_nyt_bestseller_list(slug)
    if not list_info:
        return jsonify({'error': 'Invalid bestseller list'}), 400
    if published_date != 'current' and not re.fullmatch(r'\d{4}-\d{2}-\d{2}', published_date):
        return jsonify({'error': 'Invalid bestseller week'}), 400
    try:
        data = get_cached_json(
            f'nytimes:bestsellers:{slug}:{published_date}', urljoin(NYT_BOOKS_BASE_URL, f'/svc/books/v3/lists/{published_date}/{slug}.json'),
            NYT_BOOKS_ORIGINS, headers={'User-Agent': 'Bookstack Kindle Browser'},
            params={'api-key': NYT_BOOKS_API_KEY}, cache_seconds=BESTSELLERS_CACHE_SECONDS
        )
        return jsonify({'title': list_info['title'], 'date': published_date, 'books': normalize_nyt_books(extract_nyt_books(data))})
    except Exception as e:
        print(f'[ERROR] NYT bestsellers failed: {type(e).__name__}', flush=True)
        return jsonify({'error': 'Unable to load bestsellers'}), 502


@bp.route('/bestseller-weeks')
def bestseller_weeks():
    slug = request.args.get('slug', '')
    if not NYT_BOOKS_API_KEY:
        return jsonify({'error': 'NYT Books API key is not configured'}), 503
    list_info = get_nyt_bestseller_list(slug)
    if not list_info:
        return jsonify({'error': 'Invalid bestseller list'}), 400
    return jsonify({'title': list_info['title'], 'weeks': get_nyt_bestseller_weeks(list_info)})
