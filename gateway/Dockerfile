FROM python:3.11-slim-bookworm
WORKDIR /app
RUN pip install --no-cache-dir fastapi==0.115.12 uvicorn==0.34.2 httpx==0.28.1 python-multipart==0.0.20
COPY app.py /app/app.py
EXPOSE 8500
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8500", "--workers", "1"]
