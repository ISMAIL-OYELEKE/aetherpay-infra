# syntax=docker/dockerfile:1.7
FROM python:3.12-slim AS build
ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
WORKDIR /build
COPY requirements.txt .
RUN pip install --prefix=/install -r requirements.txt

FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8080
RUN groupadd --system --gid 10001 app && useradd --system --uid 10001 --gid app --no-create-home app
COPY --from=build /install /usr/local
WORKDIR /srv
COPY aetherpay ./aetherpay
USER 10001:10001
EXPOSE 8080
# Read-only root filesystem compatible: nothing is written outside /tmp.
CMD ["python", "-m", "aetherpay.ingestor"]
