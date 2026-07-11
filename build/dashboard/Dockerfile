# Use an official lightweight Python image
FROM python:3.11-slim

WORKDIR /app

# Copy only the requirements first to leverage Docker cache
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY node_status.py .

EXPOSE 8000

CMD ["python", "node_status.py"]
