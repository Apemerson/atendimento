# frozen_string_literal: true

# Ativação limpa e resiliente dos recursos Enterprise e Personalização da Marca para Chatwoot / AstraChat
Rails.application.config.after_initialize do
  Rails.logger.info('[EnterpriseActivator] Iniciando ativação dos recursos Enterprise e Personalização de Marca...')

  # 1. Ajuste do plano de preços no ChatwootHub
  begin
    if defined?(ChatwootHub)
      ChatwootHub.singleton_class.class_eval do
        def pricing_plan
          'enterprise'
        end

        def pricing_plan_quantity
          999_999
        end
      end
    end
  rescue StandardError => e
    Rails.logger.warn("[EnterpriseActivator] Erro ao ajustar ChatwootHub: #{e.message}")
  end

  # 2. Ajuste do helper enterprise? em ChatwootApp
  begin
    if defined?(ChatwootApp)
      ChatwootApp.singleton_class.class_eval do
        def enterprise?
          true
        end
      end
    end
  rescue StandardError => e
    Rails.logger.warn("[EnterpriseActivator] Erro ao ajustar ChatwootApp: #{e.message}")
  end

  # 3. Ajuste do módulo de licença Kanban (AstraChat) - métodos de instância e de classe
  begin
    if defined?(Kanban::License)
      Kanban::License.class_eval do
        def plan; 'enterprise'; end
        def product_tier; 'enterprise'; end
        def valid?; true; end
        def quantity; 999_999; end
      end

      Kanban::License.singleton_class.class_eval do
        def plan; 'enterprise'; end
        def product_tier; 'enterprise'; end
        def valid?; true; end
        def quantity; 999_999; end
      end
    end
  rescue StandardError => e
    Rails.logger.warn("[EnterpriseActivator] Erro ao ajustar Kanban::License: #{e.message}")
  end

  # 4. Ajuste do título da aplicação no SuperAdmin (Administrate)
  begin
    if defined?(Administrate::ApplicationHelper)
      Administrate::ApplicationHelper.module_eval do
        def application_title
          GlobalConfig.get('INSTALLATION_NAME')['INSTALLATION_NAME'].presence ||
            GlobalConfig.get('BRAND_NAME')['BRAND_NAME'].presence ||
            ENV['INSTALLATION_NAME'].presence ||
            'ET Connect'
        end
      end
    end
  rescue StandardError => e
    Rails.logger.warn("[EnterpriseActivator] Erro ao ajustar Administrate::ApplicationHelper: #{e.message}")
  end

  # 5. Sincronização segura no banco de dados e limpeza de cache
  begin
    if defined?(InstallationConfig) && ActiveRecord::Base.connection.table_exists?('installation_configs')
      # Sincroniza plano Enterprise
      plan_conf = InstallationConfig.find_or_initialize_by(name: 'INSTALLATION_PRICING_PLAN')
      if plan_conf.respond_to?(:value=)
        plan_conf.value = 'enterprise'
      else
        plan_conf.serialized_value = { value: 'enterprise' }.with_indifferent_access
      end
      plan_conf.save! if plan_conf.changed?

      qty_conf = InstallationConfig.find_or_initialize_by(name: 'INSTALLATION_PRICING_PLAN_QUANTITY')
      if qty_conf.respond_to?(:value=)
        qty_conf.value = 999_999
      else
        qty_conf.serialized_value = { value: 999_999 }.with_indifferent_access
      end
      qty_conf.save! if qty_conf.changed?

      # Sincroniza marca e nome da instalação (ET Connect)
      target_brand = ENV['INSTALLATION_NAME'].presence || 'ET Connect'

      name_conf = InstallationConfig.find_or_initialize_by(name: 'INSTALLATION_NAME')
      if name_conf.respond_to?(:value=)
        name_conf.value = target_brand
      else
        name_conf.serialized_value = { value: target_brand }.with_indifferent_access
      end
      name_conf.save! if name_conf.changed?

      brand_conf = InstallationConfig.find_or_initialize_by(name: 'BRAND_NAME')
      if brand_conf.respond_to?(:value=)
        brand_conf.value = target_brand
      else
        brand_conf.serialized_value = { value: target_brand }.with_indifferent_access
      end
      brand_conf.save! if brand_conf.changed?
    end

    if defined?(GlobalConfig) && GlobalConfig.respond_to?(:clear_cache)
      GlobalConfig.clear_cache
    end

    if defined?(Account) && ActiveRecord::Base.connection.table_exists?('accounts')
      Account.find_each do |account|
        account.enable_features! if account.respond_to?(:enable_features!)
      end
    end

    Rails.logger.info('[EnterpriseActivator] Recursos Enterprise e Marca ET Connect ativados com sucesso.')
  rescue StandardError => e
    Rails.logger.warn("[EnterpriseActivator] Aviso durante sincronização: #{e.class} - #{e.message}")
  end
end
