# Establish the web process's private-network sockets before a user opens a
# forecast page. The work is asynchronous so a temporarily unavailable core
# never delays or prevents the Rails process from booting.
Rails.application.config.after_initialize do
  if Rails.env.production? && ENV["FLY_PROCESS_GROUP"] == "web"
    Thread.new do
      10.times do |attempt|
        ArtifinanceCore::Client.preconnect!
        break
      rescue ArtifinanceCore::Error
        sleep(attempt + 1)
      end
    end
  end
end
