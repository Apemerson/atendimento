ARG BASE_IMAGE=ghcr.io/apemerson/atendimentoet:v4.19.0-0.0.1
FROM ${BASE_IMAGE}

COPY app/controllers/kanban/provider_webhooks_controller.rb /app/app/controllers/kanban/provider_webhooks_controller.rb
COPY config/initializers/enterprise_features.rb /app/config/initializers/enterprise_features.rb
COPY app/views/super_admin/application/_brand.html.erb /app/app/views/super_admin/application/_brand.html.erb
