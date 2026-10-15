# frozen_string_literal: true

module IsbfCareers
  class Engine < ::Rails::Engine
    engine_name "isbf-careers"
    isolate_namespace IsbfCareers
  end

  class TopicsController < ::ApplicationController
    requires_login
    requires_plugin "isbf-careers"
    skip_before_action :check_xhr, only: :page

    def page
      category = Category.find_by(id: IsbfCareers.category_id)
      raise Discourse::NotFound unless category && guardian.can_see_category?(category)
      render html: "".html_safe, layout: "application"
    end
  end
end