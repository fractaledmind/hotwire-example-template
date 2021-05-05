class SlowImageAnalyzer < ActiveStorage::Analyzer::ImageAnalyzer
  def metadata
    sleep 10

    super
  end
end
