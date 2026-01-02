import os
import requests
import xml.etree.ElementTree as ET
import base64
import html
import re
import smtplib
from email.mime.multipart import MIMEMultipart
from email.mime.base import MIMEBase
from email import encoders
from urllib.parse import urljoin, urlparse, quote_plus
from flask import Flask, render_template, request, jsonify, make_response
from bs4 import BeautifulSoup

app = Flask(__name__)
app.secret_key = os.urandom(24)

# Server-side configuration
EPHEMERA_URL = os.environ.get('EPHEMERA_URL', 'http://ephemera:8286')
BOOKLORE_URL = os.environ.get('BOOKLORE_URL', 'http://booklore:6060/api/v1/opds')
BOOKLORE_USER = os.environ.get('BOOKLORE_USER', 'jon')
BOOKLORE_PASS = os.environ.get('BOOKLORE_PASS', 'L1ver9001#')
SMTP_SERVER = os.environ.get('SMTP_SERVER', 'smtp.gmail.com')
SMTP_PORT = int(os.environ.get('SMTP_PORT', '587'))
SMTP_USER = os.environ.get('SMTP_USER', '')
SMTP_PASS = os.environ.get('SMTP_PASS', '')

NAMESPACES = {
    'atom': 'http://www.w3.org/2005/Atom',
    'opds': 'http://opds-spec.org/2010/catalog',
    'dcterms': 'http://purl.org/dc/terms/',
    'schema': 'http://schema.org/'
}

def clean_html(raw_html):
    if not raw_html:
        return ""
    cleantext = html.unescape(raw_html)
    cleantext = re.sub(r'<[^>]+>', '', cleantext)
    cleantext = re.sub(r'\s+', ' ', cleantext).strip()
    return cleantext

def parse_opds_feed(xml_content, base_url):
    root = ET.fromstring(xml_content)
    entries = []
    
    for entry in root.findall('atom:entry', NAMESPACES):
        title_elem = entry.find('atom:title', NAMESPACES)
        id_elem = entry.find('atom:id', NAMESPACES)
        
        summary_elem = entry.find('atom:summary', NAMESPACES)
        content_elem = entry.find('atom:content', NAMESPACES)
        
        title_text = title_elem.text if title_elem is not None else "Unknown Title"
        if title_text in ['Libraries', 'Shelves', 'Magic Shelves']:
            continue

        obj = {
            'title': title_text,
            'id': id_elem.text if id_elem is not None else "",
            'links': [],
            'series_name': None,
            'series_index': None,
            'description': ""
        }
        
        series_id = None
        for meta in entry.findall('atom:meta', NAMESPACES):
            prop = meta.get('property')
            if prop == "belongs-to-collection":
                obj['series_name'] = meta.text
                series_id = meta.get('id')
            elif prop == "group-position" and series_id and meta.get('refines') == f"#{series_id}":
                obj['series_index'] = meta.text

        if not obj['series_name']:
            series_elem = entry.find('schema:Series', NAMESPACES)
            if series_elem is not None:
                obj['series_name'] = series_elem.get('name')
                obj['series_index'] = series_elem.get('position')

        raw_desc = ""
        if summary_elem is not None:
            raw_desc = summary_elem.text or ""
        elif content_elem is not None:
            raw_desc = content_elem.text or ""
        
        obj['description'] = clean_html(raw_desc)

        author = entry.find('atom:author/atom:name', NAMESPACES)
        if author is not None:
            obj['author'] = author.text

        for link in entry.findall('atom:link', NAMESPACES):
            raw_href = link.get('href')
            link_rel = link.get('rel') or ''
            
            # Convert relative URLs to use our proxy (only for images)
            if raw_href:
                if raw_href.startswith('/') and ('image' in link_rel or 'thumbnail' in link_rel):
                    # Relative image URL - proxy it through our endpoint
                    absolute_href = f"/api/opds/image-proxy?url={raw_href}"
                elif raw_href.startswith('http'):
                    # Already absolute - use as-is
                    absolute_href = raw_href
                else:
                    # Other relative URLs - make absolute using base_url
                    absolute_href = urljoin(base_url, raw_href)
            else:
                absolute_href = ""
            
            l = {
                'href': absolute_href,
                'rel': link_rel,
                'type': link.get('type')
            }
            obj['links'].append(l)

        entries.append(obj)
    return entries

@app.route('/api/settings', methods=['GET', 'POST'])
def handle_settings():
    if request.method == 'POST':
        data = request.json
        kindle_email = data.get('kindle_email', '')
        
        resp = make_response(jsonify({'status': 'saved'}))
        resp.set_cookie('kindle_email', kindle_email, max_age=365*24*60*60)  # 1 year
        return resp
    else:
        kindle_email = request.cookies.get('kindle_email', '')
        return jsonify({'kindle_email': kindle_email})

@app.route('/api/opds/image-proxy')
def image_proxy():
    url = request.args.get('url')
    if not url:
        return '', 404
    
    # If it's a relative URL, prepend BOOKLORE_URL base
    if url.startswith('/'):
        base = BOOKLORE_URL.split('/api/v1/opds')[0] if '/api/v1/opds' in BOOKLORE_URL else BOOKLORE_URL.rsplit('/', 1)[0]
        url = base + url
    
    try:
        headers = {'User-Agent': 'Mozilla/5.0'}
        if BOOKLORE_USER and BOOKLORE_PASS:
            auth_str = f"{BOOKLORE_USER}:{BOOKLORE_PASS}"
            encoded_auth = base64.b64encode(auth_str.encode('ascii')).decode('ascii')
            headers['Authorization'] = f"Basic {encoded_auth}"
        
        resp = requests.get(url, headers=headers, timeout=10)
        resp.raise_for_status()
        
        return resp.content, resp.status_code, {'Content-Type': resp.headers.get('Content-Type', 'image/jpeg')}
    except:
        return '', 404

@app.route('/api/opds/browse')
def opds_browse():
    target_url = request.args.get('url')
    
    print(f"=== OPDS BROWSE REQUEST ===", flush=True)
    print(f"Input URL: {target_url}", flush=True)
    print(f"BOOKLORE_URL env: {BOOKLORE_URL}", flush=True)
    print(f"BOOKLORE_USER env: {BOOKLORE_USER}", flush=True)
    
    if not target_url:
        target_url = BOOKLORE_URL
    elif not target_url.startswith('http'):
        # Relative path - prepend BOOKLORE_URL
        base_url = BOOKLORE_URL.rstrip('/')
        target_url = base_url + target_url
    
    print(f"Final target_url: {target_url}", flush=True)
    
    if 'shiggsy.co.uk' in target_url and target_url.startswith('http://'):
        target_url = target_url.replace('http://', 'https://', 1)

    try:
        headers = {
            'User-Agent': 'Mozilla/5.0 (Kobo) AppleWebkit/537.36 (KHTML, like Gecko)',
            'Accept': 'application/atom+xml,application/xml,text/xml,application/json'
        }

        # Always add auth for OPDS requests since we're using server-side credentials
        if BOOKLORE_USER and BOOKLORE_PASS:
            auth_str = f"{BOOKLORE_USER}:{BOOKLORE_PASS}"
            encoded_auth = base64.b64encode(auth_str.encode('ascii')).decode('ascii')
            headers['Authorization'] = f"Basic {encoded_auth}"
        
        resp = requests.get(target_url, headers=headers, timeout=15, allow_redirects=True)
        
        print(f"Response status: {resp.status_code}", flush=True)
        print(f"Response headers: {dict(resp.headers)}", flush=True)
        if resp.status_code == 403:
            print(f"403 response body: {resp.text[:500]}", flush=True)
        
        if resp.status_code == 403:
            return jsonify({
                'error': f'403 Forbidden',
                'details': f'Access denied at {target_url}. Check "Access OPDS" in Booklore settings.',
                'url': target_url,
                'response': resp.text[:200]
            }), 403
        
        resp.raise_for_status()
        
        entries = parse_opds_feed(resp.content, target_url)
        is_acquisition = any(any(l['rel'] and 'acquisition' in l['rel'] for l in e['links']) for e in entries)
        
        return jsonify({
            'entries': entries,
            'type': 'acquisition' if is_acquisition else 'navigation'
        })
    except requests.exceptions.HTTPError as e:
        return jsonify({'error': f"HTTP Error: {str(e)}"}), resp.status_code if 'resp' in locals() else 500
    except Exception as e:
        return jsonify({'error': f"Connection Error: {str(e)}"}), 500

@app.route('/api/ephemera/search')
def search_ephemera():
    query = request.args.get('q', '')
    if not query:
        return jsonify([])
    
    try:
        ephemera_url = EPHEMERA_URL.rstrip('/')
        resp = requests.get(f"{ephemera_url}/api/search", params={'q': query}, timeout=15)
        resp.raise_for_status()
        data = resp.json()
        
        if isinstance(data, dict) and 'results' in data:
            results = data.get('results', [])
        elif isinstance(data, list):
            results = data
        else:
            results = []
        
        # Filter for EPUB format
        filtered = [book for book in results if book.get('format', '').upper() == 'EPUB']
        return jsonify(filtered)
        
    except requests.exceptions.RequestException as e:
        return jsonify({'error': f'Connection error: {str(e)}'}), 500
    except Exception as e:
        return jsonify({'error': f'Error: {str(e)}'}), 500

@app.route('/api/ephemera/download', methods=['POST'])
def request_download():
    data = request.json
    md5, title = data.get('md5'), data.get('title')
    if not md5:
        return jsonify({'error': 'Missing MD5'}), 400
    try:
        ephemera_url = EPHEMERA_URL.rstrip('/')
        resp = requests.post(f"{ephemera_url}/api/download/{md5}", json={'title': title}, timeout=15)
        resp.raise_for_status()
        return jsonify(resp.json())
    except requests.exceptions.RequestException as e:
        return jsonify({'error': f'Connection error: {str(e)}'}), 500
    except Exception as e:
        return jsonify({'error': f'Error: {str(e)}'}), 500

@app.route('/api/ephemera/queue')
def get_queue():
    try:
        ephemera_url = EPHEMERA_URL.rstrip('/')
        resp = requests.get(f"{ephemera_url}/api/queue", timeout=10)
        resp.raise_for_status()
        return jsonify(resp.json())
        
    except requests.exceptions.RequestException as e:
        return jsonify({'error': f'Connection error: {str(e)}'}), 500
    except Exception as e:
        return jsonify({'error': f'Error: {str(e)}'}), 500

@app.route('/api/opds/send-to-kindle', methods=['POST'])
def send_to_kindle():
    kindle_email = request.cookies.get('kindle_email', '')
    if not kindle_email:
        return jsonify({'error': 'Kindle email not configured'}), 400
    
    data = request.json
    download_url = data.get('url')
    if not download_url:
        return jsonify({'error': 'No URL provided'}), 400
    
    try:
        # Download the book with auth
        headers = {
            'User-Agent': 'Mozilla/5.0 (Kobo) AppleWebkit/537.36'
        }
        
        # Always add auth for OPDS downloads
        if BOOKLORE_USER and BOOKLORE_PASS:
            auth_str = f"{BOOKLORE_USER}:{BOOKLORE_PASS}"
            encoded_auth = base64.b64encode(auth_str.encode('ascii')).decode('ascii')
            headers['Authorization'] = f"Basic {encoded_auth}"
        
        resp = requests.get(download_url, headers=headers, timeout=30)
        resp.raise_for_status()
        
        # Get filename from URL or content-disposition
        filename = 'book.epub'
        if 'content-disposition' in resp.headers:
            cd = resp.headers['content-disposition']
            if 'filename=' in cd:
                filename = cd.split('filename=')[1].strip('"\'')
        else:
            filename = download_url.split('/')[-1].split('?')[0] or 'book.epub'
        
        if not SMTP_USER or not SMTP_PASS:
            return jsonify({'error': 'SMTP credentials not configured in server'}), 500
        
        msg = MIMEMultipart()
        msg['From'] = SMTP_USER
        msg['To'] = kindle_email
        msg['Subject'] = 'Book from OPDS'
        
        part = MIMEBase('application', 'octet-stream')
        part.set_payload(resp.content)
        encoders.encode_base64(part)
        part.add_header('Content-Disposition', f'attachment; filename={filename}')
        msg.attach(part)
        
        server = smtplib.SMTP(SMTP_SERVER, SMTP_PORT)
        server.starttls()
        server.login(SMTP_USER, SMTP_PASS)
        server.send_message(msg)
        server.quit()
        
        return jsonify({'status': 'sent', 'filename': filename})
        
    except requests.exceptions.RequestException as e:
        return jsonify({'error': f'Download error: {str(e)}'}), 500
    except Exception as e:
        return jsonify({'error': f'Email error: {str(e)}'}), 500

@app.route('/api/bookseriesinorder/search')
def search_bookseriesinorder():
    query = request.args.get('q', '')
    if not query:
        return jsonify([])

    try:
        # Search bookseriesinorder.com with properly encoded query
        encoded_query = quote_plus(query)
        search_url = f"https://www.bookseriesinorder.com/?s={encoded_query}"
        headers = {'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'}

        print(f"[BSIO] Searching for: {query}", flush=True)
        print(f"[BSIO] URL: {search_url}", flush=True)

        resp = requests.get(search_url, headers=headers, timeout=15)
        resp.raise_for_status()

        print(f"[BSIO] Response status: {resp.status_code}", flush=True)
        print(f"[BSIO] Response length: {len(resp.content)}", flush=True)

        soup = BeautifulSoup(resp.content, 'html.parser')
        authors = []

        # Log the page structure to understand what we're working with
        all_h2 = soup.find_all('h2')
        all_h3 = soup.find_all('h3')
        print(f"[BSIO] Page has {len(all_h2)} h2 tags and {len(all_h3)} h3 tags", flush=True)

        # Debug: print what's in the h2 tags
        for idx, h2 in enumerate(all_h2):
            print(f"[BSIO] H2 #{idx}: text='{h2.get_text(strip=True)[:100]}', has_link={h2.find('a') is not None}", flush=True)

        # Try to find all links that might be author pages
        all_links = soup.find_all('a', href=True)
        print(f"[BSIO] Page has {len(all_links)} total links", flush=True)

        # Debug: Show first 10 links to understand structure, skip navigation
        for idx, link in enumerate(all_links[:15]):
            href = link.get('href', '')
            text = link.get_text(strip=True)[:50]
            # Look for links that might be author pages
            if 'bookseriesinorder.com' in href and href not in ['https://www.bookseriesinorder.com', 'https://www.bookseriesinorder.com/']:
                print(f"[BSIO] Link #{idx}: text='{text}', href='{href}'", flush=True)

        # Look for common WordPress content containers
        content_areas = [
            soup.find('main'),
            soup.find('div', id='content'),
            soup.find('div', class_='site-content'),
            soup.find('div', class_='hfeed'),
            soup.find('ul', class_='search-results'),
            soup.find('div', class_='search-results')
        ]

        for idx, area in enumerate(content_areas):
            if area:
                print(f"[BSIO] Found content area #{idx}: {area.name}.{area.get('class', [])} with {len(area.find_all('a', href=True))} links", flush=True)

        # Strategy 1: Look for article elements
        articles = soup.find_all('article')
        print(f"[BSIO] Found {len(articles)} article elements", flush=True)

        if not articles:
            # Strategy 2: Look for divs with post-related classes
            articles = soup.find_all('div', class_=lambda x: x and any(c in str(x).lower() for c in ['post', 'search-result', 'result']))
            print(f"[BSIO] Fallback: Found {len(articles)} div elements with post/result classes", flush=True)

        if not articles:
            # Strategy 3: Look for any container with h2/h3 headings that have links
            # This is a more generic approach
            print(f"[BSIO] Using generic strategy - looking for heading links", flush=True)
            for h_tag in soup.find_all(['h2', 'h3']):
                link = h_tag.find('a', href=True)
                if link:
                    author_name = link.get_text(strip=True)
                    author_url = link.get('href', '')

                    print(f"[BSIO] Found h2/h3 with link: '{author_name}' -> {author_url}", flush=True)

                    # Accept links that:
                    # 1. Are not empty or just #
                    # 2. Start with http/https (absolute URLs) OR start with / (relative URLs)
                    # 3. Look like author pages (not search results, categories, tags, etc.)
                    is_valid = False
                    if author_url and author_url != '#':
                        if 'bookseriesinorder.com' in author_url and '/tag/' not in author_url and '/category/' not in author_url:
                            is_valid = True
                        elif author_url.startswith('/') and author_url not in ['/', '/?s=']:
                            # Relative URL - make it absolute
                            author_url = 'https://www.bookseriesinorder.com' + author_url
                            if '/tag/' not in author_url and '/category/' not in author_url:
                                is_valid = True

                    if is_valid:
                        # Try to find description nearby
                        description = ''
                        # Look for next sibling that might contain description
                        next_elem = h_tag.find_next_sibling()
                        if next_elem and next_elem.name in ['p', 'div']:
                            description = next_elem.get_text(strip=True)[:200]

                        print(f"[BSIO] Found author via heading: {author_name}", flush=True)
                        authors.append({
                            'name': author_name,
                            'url': author_url,
                            'description': description
                        })
                    else:
                        print(f"[BSIO] Skipped (not valid author page): {author_url}", flush=True)

            # Strategy 4: If no authors found yet, collect all bookseriesinorder.com links
            if len(authors) == 0:
                print(f"[BSIO] No authors from h2/h3, trying Strategy 4: collect all author page links", flush=True)

                seen_urls = set()

                for link in all_links:
                    href = link.get('href', '')
                    text = link.get_text(strip=True)

                    # Skip if no text or href
                    if not text or not href:
                        continue

                    # Check if this is a bookseriesinorder.com author page
                    if 'bookseriesinorder.com' in href:
                        # Normalize URL
                        if not href.startswith('http'):
                            href = 'https://www.bookseriesinorder.com' + href

                        # Skip homepage
                        if href in ['https://www.bookseriesinorder.com', 'https://www.bookseriesinorder.com/']:
                            continue

                        # Skip navigation and non-author pages using more specific checks
                        # Extract path from URL
                        if '?' in href:
                            path_part = href.split('?')[0]
                        else:
                            path_part = href

                        # Skip specific paths
                        skip_patterns = [
                            '/characters/', '/authors/', '/book-release-calendar/',
                            '/about/', '/contact/', '/privacy-policy/', '/tag/', '/category/',
                            '/page/'
                        ]

                        should_skip = False
                        for pattern in skip_patterns:
                            if pattern in path_part:
                                should_skip = True
                                break

                        # Skip if it's a search URL
                        if '?s=' in href:
                            should_skip = True

                        # Skip if we've seen this URL or if it should be skipped
                        if should_skip or href in seen_urls:
                            continue

                        seen_urls.add(href)

                        # Filter out junk/promotional links
                        junk_phrases = [
                            'book notification', 'click here', 'check out this great series',
                            'privacy policy', 'cookie policy', 'terms of service',
                            'click', 'here', 'notification'
                        ]

                        is_junk = False
                        text_lower = text.lower()
                        for junk in junk_phrases:
                            if junk in text_lower:
                                is_junk = True
                                print(f"[BSIO] Skipped junk link: {text}", flush=True)
                                break

                        if is_junk:
                            continue

                        # Look for description nearby
                        description = ''
                        parent = link.parent
                        if parent:
                            # Try to find description text near the link
                            next_sibling = link.find_next_sibling()
                            if next_sibling and next_sibling.name == 'p':
                                description = next_sibling.get_text(strip=True)[:200]

                        print(f"[BSIO] Found author via link collection: {text}", flush=True)
                        authors.append({
                            'name': text,
                            'url': href,
                            'description': description
                        })
        else:
            # Process articles normally
            for article in articles:
                # Try to find title with multiple approaches
                title_elem = article.find('h2', class_='entry-title')
                if not title_elem:
                    title_elem = article.find('h2')
                if not title_elem:
                    title_elem = article.find('h3', class_='entry-title')
                if not title_elem:
                    title_elem = article.find('h3')
                if not title_elem:
                    title_elem = article.find('h1')
                if not title_elem:
                    continue

                link_elem = title_elem.find('a')
                if not link_elem:
                    # Try to find any link in the article
                    link_elem = article.find('a', href=True)
                if not link_elem:
                    continue

                author_name = link_elem.get_text(strip=True)
                author_url = link_elem.get('href', '')

                # Skip if URL doesn't look valid
                if not author_url or author_url == '#':
                    continue

                # Get the excerpt/description
                excerpt_elem = article.find('div', class_='entry-summary')
                if not excerpt_elem:
                    excerpt_elem = article.find('div', class_=lambda x: x and 'summary' in x.lower() if x else False)
                if not excerpt_elem:
                    excerpt_elem = article.find('div', class_=lambda x: x and 'excerpt' in x.lower() if x else False)
                if not excerpt_elem:
                    excerpt_elem = article.find('p')

                description = ''
                if excerpt_elem:
                    # Get text content
                    if excerpt_elem.name == 'p':
                        description = excerpt_elem.get_text(strip=True)
                    else:
                        p_elem = excerpt_elem.find('p')
                        if p_elem:
                            description = p_elem.get_text(strip=True)

                print(f"[BSIO] Found author: {author_name}", flush=True)

                authors.append({
                    'name': author_name,
                    'url': author_url,
                    'description': description
                })

        print(f"[BSIO] Total authors found: {len(authors)}", flush=True)
        return jsonify(authors)

    except requests.exceptions.RequestException as e:
        print(f"[BSIO] Request error: {str(e)}", flush=True)
        return jsonify({'error': f'Connection error: {str(e)}'}), 500
    except Exception as e:
        print(f"[BSIO] Error: {str(e)}", flush=True)
        import traceback
        traceback.print_exc()
        return jsonify({'error': f'Error: {str(e)}'}), 500

@app.route('/api/bookseriesinorder/author')
def get_author_books():
    author_url = request.args.get('url', '')
    if not author_url:
        return jsonify({'error': 'No URL provided'}), 400

    try:
        headers = {'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'}

        print(f"[BSIO-Author] Fetching: {author_url}", flush=True)
        resp = requests.get(author_url, headers=headers, timeout=15)
        resp.raise_for_status()

        soup = BeautifulSoup(resp.content, 'html.parser')

        # Find the author name from the page title or h1
        author_name = ''
        h1_elem = soup.find('h1', class_='entry-title')
        if h1_elem:
            author_name = h1_elem.get_text(strip=True)

        if not author_name:
            h1_elem = soup.find('h1')
            if h1_elem:
                author_name = h1_elem.get_text(strip=True)

        print(f"[BSIO-Author] Author name: {author_name}", flush=True)

        series_list = []

        # Debug: Show page structure
        all_divs = soup.find_all('div', class_=True)
        print(f"[BSIO-Author] Page has {len(all_divs)} divs with classes", flush=True)

        # Show first 10 div classes
        for idx, div in enumerate(all_divs[:10]):
            classes = ' '.join(div.get('class', []))
            print(f"[BSIO-Author] Div #{idx}: classes='{classes}'", flush=True)

        # Find all series sections
        content = soup.find('div', class_='entry-content')
        if not content:
            content = soup.find('main')
        if not content:
            content = soup.find('article')
        if not content:
            # Try to find any div with 'content' in class name
            content = soup.find('div', class_=lambda x: x and 'content' in ' '.join(x).lower())
        if not content:
            # Last resort: use body
            content = soup.find('body')

        print(f"[BSIO-Author] Content area found: {content is not None}, type: {content.name if content else None}", flush=True)

        if not content:
            return jsonify({'author': author_name, 'series': []})

        # Count h2, h3, h4 tags
        h2_tags = content.find_all('h2')
        h3_tags = content.find_all('h3')
        h4_tags = content.find_all('h4')
        print(f"[BSIO-Author] Found {len(h2_tags)} h2, {len(h3_tags)} h3, {len(h4_tags)} h4 tags", flush=True)

        # Try h2, h3, and h4 for series headers
        current_series = None

        for elem in content.find_all(['h2', 'h3', 'h4', 'ul', 'ol', 'p', 'table']):
            if elem.name in ['h2', 'h3', 'h4']:
                # New series header
                series_name = elem.get_text(strip=True)

                # Skip non-series headers and comments/reply sections
                skip_headers = [
                    'about the author', 'author bio', 'biography', 'share this', 'related', 'tags',
                    'leave a reply', 'responses to', 'comments', 'chronological order', 'similar authors',
                    'also read', 'recommended', 'you may also like'
                ]
                if any(skip in series_name.lower() for skip in skip_headers):
                    print(f"[BSIO-Author] Skipping header: {series_name}", flush=True)
                    current_series = None  # Reset current series so nothing gets added to it
                    continue

                if series_name and len(series_name) > 0:
                    current_series = {
                        'name': series_name,
                        'books': []
                    }
                    series_list.append(current_series)
                    print(f"[BSIO-Author] Found series: {series_name}", flush=True)

                    # Debug: show what comes after this header
                    next_sibling = elem.find_next_sibling()
                    if next_sibling:
                        print(f"[BSIO-Author]   Next sibling: {next_sibling.name}, classes: {next_sibling.get('class', [])}", flush=True)

            elif elem.name == 'table' and current_series is not None:
                # Books in a table (common format)
                for row in elem.find_all('tr'):
                    cells = row.find_all(['td', 'th'])
                    if len(cells) > 0:
                        # First cell usually contains the book title
                        book_text = cells[0].get_text(strip=True)

                        # Try to find Amazon link in any cell
                        amazon_link = ''
                        for cell in cells:
                            link_elem = cell.find('a', href=True)
                            if link_elem:
                                href = link_elem.get('href', '')
                                if 'amazon.com' in href or 'amzn.to' in href:
                                    amazon_link = href
                                    break

                        if book_text and book_text.lower() not in ['title', 'book', 'year', 'date']:
                            current_series['books'].append({
                                'title': book_text,
                                'amazon_link': amazon_link
                            })
                            print(f"[BSIO-Author]   - Book (table): {book_text[:50]}", flush=True)

            elif elem.name == 'p' and current_series is not None:
                # Books in paragraphs (each p is a book)
                book_text = elem.get_text(strip=True)

                # Skip if it's just a description paragraph
                if len(book_text) > 200:
                    continue

                # Skip if it's a concatenated numbered list (e.g., "1: Book1 2: Book2 3: Book3")
                # These typically have multiple numbers followed by colons
                if re.search(r'\d+:.*\d+:.*\d+:', book_text):
                    print(f"[BSIO-Author]   - Skipped paragraph (numbered list): {book_text[:50]}", flush=True)
                    continue

                # Skip if it contains phrases like "Then read" or "Read in order"
                if any(phrase in book_text.lower() for phrase in ['then read', 'read in', 'in order', 'order to read']):
                    print(f"[BSIO-Author]   - Skipped paragraph (instructions): {book_text[:50]}", flush=True)
                    continue

                # Try to find Amazon link
                amazon_link = ''
                link_elem = elem.find('a', href=True)
                if link_elem:
                    href = link_elem.get('href', '')
                    if 'amazon.com' in href or 'amzn.to' in href:
                        amazon_link = href

                if book_text and '(' in book_text:  # Usually books have (year) in them
                    current_series['books'].append({
                        'title': book_text,
                        'amazon_link': amazon_link
                    })
                    print(f"[BSIO-Author]   - Book (p): {book_text[:50]}", flush=True)

            elif (elem.name == 'ul' or elem.name == 'ol') and current_series is not None:
                # Books list for current series
                for li in elem.find_all('li', recursive=False):
                    book_text = li.get_text(strip=True)

                    # Skip if it's a comment or form element
                    if any(skip in book_text.lower() for skip in ['name', 'email', 'comment', 'ago', 'months ago', 'year ago', 'weeks ago']):
                        continue

                    # Skip if it's just an author name (too short, no year, no special chars)
                    # Books typically have at least 10 chars and contain numbers or special formatting
                    if len(book_text) < 10 or not re.search(r'[\d\(\)]', book_text):
                        print(f"[BSIO-Author]   - Skipped (not a book): {book_text[:50]}", flush=True)
                        continue

                    # Try to find Amazon link
                    amazon_link = ''
                    link_elem = li.find('a', href=True)
                    if link_elem:
                        href = link_elem.get('href', '')
                        if 'amazon.com' in href or 'amzn.to' in href:
                            amazon_link = href

                    if book_text:
                        current_series['books'].append({
                            'title': book_text,
                            'amazon_link': amazon_link
                        })
                        print(f"[BSIO-Author]   - Book (list): {book_text[:50]}", flush=True)

        # Remove empty series
        series_list = [s for s in series_list if len(s['books']) > 0]

        print(f"[BSIO-Author] Total series with books: {len(series_list)}", flush=True)

        return jsonify({
            'author': author_name,
            'series': series_list
        })

    except requests.exceptions.RequestException as e:
        print(f"[BSIO-Author] Request error: {str(e)}", flush=True)
        return jsonify({'error': f'Connection error: {str(e)}'}), 500
    except Exception as e:
        print(f"[BSIO-Author] Error: {str(e)}", flush=True)
        import traceback
        traceback.print_exc()
        return jsonify({'error': f'Error: {str(e)}'}), 500

@app.route('/api/opds/check-library', methods=['POST'])
def check_library():
    """Check if books are in the OPDS library"""
    data = request.json
    book_titles = data.get('titles', [])
    author_name = data.get('author', '')

    if not book_titles:
        return jsonify({'results': {}})

    try:
        # Search the OPDS library for the author
        search_url = f"{BOOKLORE_URL}/search?q={author_name}"

        headers = {
            'User-Agent': 'Mozilla/5.0 (Kobo) AppleWebkit/537.36'
        }

        if BOOKLORE_USER and BOOKLORE_PASS:
            auth_str = f"{BOOKLORE_USER}:{BOOKLORE_PASS}"
            encoded_auth = base64.b64encode(auth_str.encode('ascii')).decode('ascii')
            headers['Authorization'] = f"Basic {encoded_auth}"

        resp = requests.get(search_url, headers=headers, timeout=10)

        if resp.status_code != 200:
            return jsonify({'results': {}})

        # Parse OPDS feed
        entries = parse_opds_feed(resp.content, search_url)

        print(f"[Library Check] OPDS search returned {len(entries)} entries for author '{author_name}'", flush=True)

        # Log first 5 OPDS entries for debugging
        for idx, entry in enumerate(entries[:5]):
            print(f"[Library Check]   OPDS entry #{idx}: '{entry['title']}'", flush=True)

        # Check which books are in library
        results = {}
        for book_title in book_titles:
            # Normalize title for comparison - remove text in brackets and year
            title_normalized = re.sub(r'\([^)]*\)', '', book_title)  # Remove anything in parentheses
            title_normalized = re.sub(r'\s+', ' ', title_normalized).strip()  # Clean up extra spaces
            title_lower = title_normalized.lower()

            print(f"[Library Check] Checking '{book_title}' -> normalized: '{title_normalized}'", flush=True)

            found_entry = None
            best_match_score = 0

            for entry in entries:
                # Normalize OPDS entry title the same way
                entry_title = entry['title']
                entry_normalized = re.sub(r'\([^)]*\)', '', entry_title)
                entry_normalized = re.sub(r'\s+', ' ', entry_normalized).strip()
                entry_lower = entry_normalized.lower()

                # Calculate match score
                # Perfect match gets 100
                if title_lower == entry_lower:
                    match_score = 100
                # Title contains entry or entry contains title
                elif title_lower in entry_lower or entry_lower in title_lower:
                    # Calculate overlap percentage
                    if len(title_lower) > len(entry_lower):
                        match_score = int((len(entry_lower) / len(title_lower)) * 100)
                    else:
                        match_score = int((len(title_lower) / len(entry_lower)) * 100)
                else:
                    # Check word-by-word match
                    title_words = set(title_lower.split())
                    entry_words = set(entry_lower.split())
                    common_words = title_words & entry_words
                    if len(common_words) > 0:
                        match_score = int((len(common_words) / max(len(title_words), len(entry_words))) * 100)
                    else:
                        match_score = 0

                # Consider it a match if score is 70% or higher
                if match_score >= 70 and match_score > best_match_score:
                    best_match_score = match_score
                    # Find the acquisition link
                    download_url = None
                    for link in entry['links']:
                        if link['rel'] and 'acquisition' in link['rel']:
                            download_url = link['href']
                            break

                    found_entry = {
                        'in_library': True,
                        'match_score': match_score,
                        'opds_title': entry_title,
                        'download_url': download_url
                    }

            if found_entry:
                print(f"[Library Check] Found match: '{found_entry['opds_title']}' (score: {found_entry['match_score']}%)", flush=True)
                results[book_title] = found_entry
            else:
                print(f"[Library Check] No match found", flush=True)
                results[book_title] = {'in_library': False}

        return jsonify({'results': results})

    except Exception as e:
        print(f"[Library Check] Error: {str(e)}", flush=True)
        import traceback
        traceback.print_exc()
        return jsonify({'results': {}})

@app.route('/')
def index():
    return render_template('index.html')

if __name__ == '__main__':
    print(f"=== SERVER STARTUP ===")
    print(f"EPHEMERA_URL: {EPHEMERA_URL}")
    print(f"BOOKLORE_URL: {BOOKLORE_URL}")
    print(f"BOOKLORE_USER: {BOOKLORE_USER}")
    print(f"SMTP_USER: {SMTP_USER}")
    app.run(host='0.0.0.0', port=5000)
