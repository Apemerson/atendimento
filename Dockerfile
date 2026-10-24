ARG BASE_IMAGE=ghcr.io/apemerson/atendimentoet:v4.18.0-0.0.5
FROM ${BASE_IMAGE}

COPY app/controllers/kanban/provider_webhooks_controller.rb /app/app/controllers/kanban/provider_webhooks_controller.rb
