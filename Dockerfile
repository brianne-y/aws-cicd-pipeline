FROM python:3.12-slim

WORKDIR /app

# Running as root inside a container is a security risk
RUN groupadd -r appuser && useradd -r -g appuser appuser

# Copy requirements before the app code so Docker can cache this layer
# If only app.py changes, pip does not reinstall everything from scratch
COPY requirements.txt .

RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

RUN chown -R appuser:appuser /app

USER appuser

EXPOSE 5000

# ECS uses this to decide if the container is healthy before sending traffic
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:5000/health')" || exit 1

CMD ["python", "-u", "app.py"]