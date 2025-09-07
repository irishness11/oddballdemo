from flask import Flask, jsonify
app = Flask(__name__)
@app.get("/")
def health():
    return jsonify(message="Hello Oddball!", status="ok")
