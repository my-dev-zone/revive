class ForkNewApp
  include Sidekiq::Worker
  
  def perform(heroku_app_id, number_of_apps_running)
    heroku_app = HerokuApp.using(:processor).find(heroku_app_id)
    heroku_app.update(name: "revivecrawler#{heroku_app.crawl.id}")
    HerokuPlatform.fork(HerokuPlatform::APP_NAME, "revivecrawler#{heroku_app.crawl.id}", heroku_app_id, number_of_apps_running)
  end
  
  def on_complete(status, options)
    batch = HerokuApp.using(:processor).where(batch_id: "#{options['bid']}").first
    if !batch.nil?
      if batch.status == 'retry'
        puts "heroku app is going to retry recreating"
      else
        puts "heroku app is created with the following id #{options['bid']}"
        HerokuPlatform.migrate_db(batch.name)
        # UserDashboard.add_running_crawl(crawl.user.user_dashboard.id)
        Api.delay_for(2.minute).migrate_db(crawl_id: batch.crawl_id)
        Api.delay_for(3.minute).start_crawl(crawl_id: batch.crawl_id)
        # Api.delay.start_crawl(crawl_id: batch.crawl_id)
      end
    end
  end
  
  def self.retry(heroku_app_id, number_of_apps_running)
    batch.jobs do
      ForkNewApp.perform_async(heroku_app_id, number_of_apps_running)
    end
  end
  
  def self.start(user_id, number_of_apps_running)
    crawl_to_start = HerokuApp.using(:processor).where(status: 'pending', user_id: user_id).order(:position).first
    
    batch = Sidekiq::Batch.new
    puts "heroku app bacth id is #{batch.bid}"
    crawl_to_start.update(status: "starting", started_at: Time.now, batch_id: batch.bid)
    batch.on(:complete, ForkNewApp, 'bid' => batch.bid)

    batch.jobs do
      ForkNewApp.perform_async(crawl_to_start.id, number_of_apps_running)
    end
  end
  
end