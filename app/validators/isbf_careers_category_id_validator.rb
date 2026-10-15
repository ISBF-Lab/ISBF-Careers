# frozen_string_literal: true

class IsbfCareersCategoryIdValidator
  def initialize(_opts = {})
  end

  def valid_value?(value)
    return false unless value.to_s.match?(/\A\d+\z/)
    id = value.to_i
    return true if id.zero?
    return false unless Category.exists?(id: id)
    %i[isbf_marketplace_category_id isbf_teamup_category_id isbf_learning_category_id isbf_library_category_id academy_official_category].none? do |setting|
      SiteSetting.respond_to?(setting) && SiteSetting.public_send(setting).to_i == id
    end
  end

  def error_message
    I18n.t("isbf_careers.invalid_category")
  end
end