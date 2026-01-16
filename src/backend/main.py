from flask import Flask, jsonify
import os
import psycopg2 # Ensure this is in requirements.txt

app = Flask(__name__)

# Production Tip: Always use environment variables for DB connections
DB_HOST = os.getenv('DB_HOST', 'localhost')
DB_NAME = os.getenv('DB_NAME', 'myapp')
DB_USER = os.getenv('DB_USER', 'admin')
DB_PASS = os.getenv('DB_PASS', 'password')

@app.route('/health', methods=['GET'])
def health_check():
    # EKS uses this to know if your pod is healthy
    return jsonify({"status": "healthy"}), 200

@app.route('/api/data', methods=['GET'])
def get_data():
    # Example logic to fetch from the 3rd tier (Database)
    return jsonify({
        "message": "Hello from the BMW 3-Tier Backend!",
        "database_connected_to": DB_HOST,
        "tier": "Application Layer"
    })

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)