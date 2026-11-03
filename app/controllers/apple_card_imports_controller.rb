# Apple Card statements (CSV or OFX from Wallet) dropped on a page or picked in a file dialog.
# Each file imports on its own: one that isn't an Apple Card statement fails alone.
class AppleCardImportsController < ApplicationController
  MAX_FILE_SIZE = 5.megabytes

  def create
    files = Array(params[:files]).select { |f| f.respond_to?(:read) }
    return render(json: { error: t(".no_files") }, status: :unprocessable_entity) if files.empty?

    results = files.map { |file| import(file) }
    Current.user.update!(onboarded_at: Time.current) if Current.user.needs_onboarding? && results.any? { |r| r[:added] }

    render json: { results: results }
  end

  private
    def import(file)
      name = file.original_filename.to_s
      return { file: name, error: t(".too_large") } if file.size > MAX_FILE_SIZE

      AppleCardStatement.new(filename: name, content: file.read).import_into(Current.family, owner: Current.user)
    rescue AppleCardStatement::Invalid => e
      { file: name, error: e.message }
    end
end
