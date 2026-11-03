class WarmArtifinanceCorePagesJob < ApplicationJob
  queue_as :low_priority
  sidekiq_options lock: :until_executed, on_conflict: :log

  def perform(family_id: nil)
    if family_id.present?
      warm_family(family_id)
    else
      Family.joins(:users).where(users: { active: true }).distinct.find_each do |family|
        self.class.perform_later(family_id: family.id)
      end
    end
  end

  private
    def warm_family(family_id)
      return unless Family.exists?(family_id)

      ArtifinanceCore.call("warm_pages", { family_id: family_id }, timeout: 60)
    end
end
