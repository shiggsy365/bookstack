from flask import Flask, jsonify, make_response, render_template, request

from bookstack_app.delivery import bp as delivery_bp
from bookstack_app.discovery import bp as discovery_bp
from bookstack_app.opds import bp as opds_bp
from bookstack_app.series_order import bp as series_order_bp
from bookstack_app.shelfmark import bp as shelfmark_bp


def create_app():
    app = Flask(__name__)
    app.register_blueprint(discovery_bp)
    app.register_blueprint(opds_bp)
    app.register_blueprint(delivery_bp)
    app.register_blueprint(shelfmark_bp)
    app.register_blueprint(series_order_bp)

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

    @app.route('/')
    def index():
        resp = make_response(render_template('index.html'))
        resp.headers['Cache-Control'] = 'no-store, no-cache, must-revalidate, max-age=0'
        resp.headers['Pragma'] = 'no-cache'
        resp.headers['Expires'] = '0'
        return resp

    return app


app = create_app()


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)
