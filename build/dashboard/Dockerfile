# Use an official lightweight Python image
FROM python:3.14-slim@sha256:b877e50bd90de10af8d82c57a022fc2e0dc731c5320d762a27986facfc3355c1

WORKDIR /app

# Build context is the repo root (see docker-compose.yml) so the top-level
# VERSION file can be baked in — the dashboard reads it, so the shown version
# always matches the running code regardless of how it was deployed.

# Copy only the requirements first to leverage Docker cache
COPY build/dashboard/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# All dashboard modules (tests/ is a subdir, not matched by the flat glob), so a
# new module is picked up automatically — no need to list each one.
COPY build/dashboard/*.py ./
COPY build/dashboard/static ./static
COPY VERSION ./VERSION

EXPOSE 8000

CMD ["python", "node_status.py"]
