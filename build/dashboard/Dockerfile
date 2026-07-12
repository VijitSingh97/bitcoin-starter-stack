# Use an official lightweight Python image
FROM python:3.14-slim@sha256:b877e50bd90de10af8d82c57a022fc2e0dc731c5320d762a27986facfc3355c1

WORKDIR /app

# Copy only the requirements first to leverage Docker cache
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY node_status.py monitor.py fee_history.py ./
COPY static ./static

EXPOSE 8000

CMD ["python", "node_status.py"]
