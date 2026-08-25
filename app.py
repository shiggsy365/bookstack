from flask import Flask, jsonify, make_response, render_template, request
from flask_compress import Compress

from bookstack_app.cache import provider_metrics

from bookstack_app.delivery import bp as delivery_bp
from bookstack_app.discovery import bp as discovery_bp
from bookstack_app.opds import bp as opds_bp
from bookstack_app.series_order import bp as series_order_bp
from bookstack_app.shelfmark import bp as shelfmark_bp


def create_app():
    app = Flask(__name__)
    app.config['COMPRESS_MIMETYPES'] = ['text/html', 'text/css', 'application/json', 'application/javascript']
    app.config['COMPRESS_MIN_SIZE'] = 500
    Compress(app)
    app.register_blueprint(discovery_bp)
    app.register_blueprint(opds_bp)
    app.register_blueprint(delivery_bp)
    app.register_blueprint(shelfmark_bp)
    app.register_blueprint(series_order_bp)

    @app.after_request
    def cache_headers(response):
        if request.method == 'GET' and response.status_code == 200:
            if request.path.startswith('/api/discovery/'):
                response.headers.setdefault('Cache-Control', 'public, max-age=60')
            elif request.path == '/api/opds/browse':
                response.headers.setdefault('Cache-Control', 'private, max-age=30')
            elif request.path.startswith('/health'):
                response.headers['Cache-Control'] = 'no-store'
        return response

    @app.route('/api/settings', methods=['GET', 'POST'])
    def settings():
        if request.method == 'POST':
            data = request.get_json(silent=True) or {}
            resp = make_response(jsonify({'status': 'saved'}))
            resp.set_cookie('kindle_email', data.get('kindle_email', ''), max_age=365 * 24 * 60 * 60, samesite='Lax')
            return resp
        return jsonify({'kindle_email': request.cookies.get('kindle_email', '')})

    @app.route('/healthz')
    def healthz():
        return jsonify({'status': 'ok'})

    @app.route('/health/providers')
    def provider_health():
        return jsonify({'status': 'ok', 'metrics': provider_metrics()})

    @app.route('/')
    def index():
        resp = make_response(render_template('index.html'))
        resp.headers['Cache-Control'] = 'private, max-age=0, must-revalidate'
        resp.add_etag()
        return resp

    return app


app = create_app()


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)
