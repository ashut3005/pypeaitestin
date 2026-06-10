from flask import Flask

app = Flask(__name__)


@app.route("/")
def home():
    """Health check endpoint."""
    return {"message": "Hello from Felix"}, 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)