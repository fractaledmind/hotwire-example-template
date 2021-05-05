class Upload < ApplicationRecord
  has_one_attached :file

  after_touch -> { broadcast_replace_later if file.analyzed? }
end
