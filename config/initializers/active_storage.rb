Rails.application.config.active_storage.analyzers.prepend SlowImageAnalyzer

ActiveSupport.on_load :active_storage_blob do
  def analyze
    super
    attachments.each(&:touch)
  end
end
