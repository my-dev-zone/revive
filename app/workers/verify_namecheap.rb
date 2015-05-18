require 'domainatrix'
require 'unirest'

class VerifyNamecheap
  include Sidekiq::Worker
  sidekiq_options :queue => :verify_domains
  sidekiq_options :retry => false
  
  def perform(redis_id)

    # START OF VERIFY DOMAIN STATUS
    page_from_redis = $redis.get(redis_id)
    puts "the page from redis is #{page_from_redis}"
    if !page_from_redis.nil?
      page = JSON.parse(page_from_redis)
      puts "verify namecheap: the page object is #{page}"

      begin
        puts 'found page to verify namecheap'
        url = Domainatrix.parse("#{page['url']}")
        if !url.domain.empty? && !url.public_suffix.empty?
          puts "here is the parsed url #{page['url']}"
          parsed_url = url.domain + "." + url.public_suffix
          
          if !Rails.cache.read(["crawl/#{page['crawl_id']}/checked"]).include?(parsed_url)
            puts "checking url #{parsed_url} on namecheap"
            avl = Set.new(Rails.cache.read(["crawl/#{page['crawl_id']}/checked"]))
            Rails.cache.write(["crawl/#{page['crawl_id']}/checked"], avl.add("#{parsed_url}").to_a)
            uri = URI.parse("https://nametoolkit-name-toolkit.p.mashape.com/beta/whois/#{parsed_url}")
            http = Net::HTTP.new(uri.host, uri.port)
            http.use_ssl = true
            request = Net::HTTP::Get.new(uri.request_uri)
            request["X-Mashape-Key"] = "6CWhVxnwLhmshW8UaLSYUSlMocdqp1kkOR4jsnmEFj0MrrHB5T"
            request["Accept"] = "application/json"
            response = http.request(request)
            json = JSON.parse(response.read_body)
            puts "the domain verification response is #{json}"
            tlds = [".gov", ".edu"]
            if json['available'].to_s == 'true' && !Rails.cache.read(["crawl/#{page['crawl_id']}/available"]).include?("#{parsed_url}") && !tlds.any?{|tld| parsed_url.include?(tld)}         
              puts "saving verified domain with the following data processor_name: #{page['processor_name']}, status_code: #{page['status_code']}, url: #{page['url']}, internal: #{page['internal']}, site_id: #{page['site_id']}, found_on: #{page['found_on']}, simple_url: #{parsed_url}, verified: true, available: #{json['available']}, crawl_id: #{page['crawl_id']}"
              
              set = Set.new(Rails.cache.read(["crawl/#{page['crawl_id']}/available"]))
              Rails.cache.write(["crawl/#{page['crawl_id']}/available"], set.add("#{parsed_url}").to_a)
              
              new_page = Page.using("#{page['processor_name']}").create(status_code: page['status_code'], url: page['url'], internal: page['internal'], site_id: page['site_id'].to_i, found_on: page['found_on'], simple_url: parsed_url, verified: true, available: "#{json['available']}", crawl_id: page['crawl_id'].to_i, redis_id: redis_id)
              puts "VerifyNamecheap: saved verified domain #{new_page.id}"

              Rails.cache.increment(["crawl/#{page['crawl_id']}/expired_domains"])
              Rails.cache.increment(["site/#{page['site_id']}/expired_domains"])
      
              page_hash = {}
      
              puts 'sync moz perform on perform'
              # client = Linkscape::Client.new(:accessID => "member-8967f7dff3", :secret => "8b98d4acd435d50482ebeded953e2331")
              # response = client.urlMetrics([parsed_url], :cols => :all)
              response = VerifyNamecheap.moz(parsed_url)
              
              if !response['error_message'].nil?
                page_hash[:da] = response['pda'].to_f
                page_hash[:pa] = response['upa'].to_f
              else
                puts "moz response error: #{response['error_message']}"
              end
      
              puts 'finished checking moz sync'
      
              puts 'sync majestic perform on perform'
              m = MajesticSeo::Api::Client.new(api_key: ENV['majestic_api_key'], environment: ENV['majestic_env'])
              res = m.get_index_item_info([parsed_url])

              res.items.each do |r|
                puts "majestic block perform #{r.response['CitationFlow']}"
                page_hash[:citationflow] = r.response['CitationFlow'].to_f
                page_hash[:trustflow] = r.response['TrustFlow'].to_f
                page_hash[:trustmetric] = r.response['TrustMetric'].to_f
                page_hash[:refdomains] = r.response['RefDomains'].to_i
                page_hash[:backlinks] = r.response['ExtBackLinks'].to_i
              end
      
              puts 'finished checking majestic sync'
      
              puts "VerifyNamecheap about to save page #{page_hash}"
              Page.using("#{page['processor_name']}").update(new_page.id, page_hash)
            else
              puts 'url already included'
            end
          end
        else
          puts 'url already included'
        end
      rescue
        puts "VerifyNamecheap failed"
        # puts "VerifyNamecheap: calling start perform method 2"
        # VerifyNamecheap.delay.start
      end
      
    else
      puts "VerifyNamecheap no page found on redis"
      puts "VerifyNamecheap: calling start perform method 3"
      VerifyNamecheap.delay(:queue => 'verify_domains').start
    end
    
    # END OF VERIFY DOMAIN STATUS

  end
  
  def on_complete(status, options)
    puts "VerifyNamecheap: calling start on_complete"
    VerifyNamecheap.delay(:queue => 'verify_domains').start
  end
  
  def self.start
    puts "VerifyNamecheap: start method"
    expired_rotation = Rails.cache.read(['expired_rotation']).to_a
    puts "the current expired crawl rotation is #{expired_rotation}"
    next_crawl_to_process = expired_rotation[0]
    all_expired_ids = Rails.cache.read(["crawl/#{next_crawl_to_process}/expired_ids"]).to_a
    next_expired_id_to_verify = all_expired_ids[0]
    
    if !next_expired_id_to_verify.nil?
      puts "going to verify page #{next_expired_id_to_verify} for the crawl #{next_crawl_to_process}"
      Rails.cache.write(['domain_being_verified'], [next_expired_id_to_verify])
      puts "the domain to be verified is #{next_expired_id_to_verify}"
      new_expired_rotation = expired_rotation.rotate
      Rails.cache.write(['expired_rotation'], new_expired_rotation)
      puts "updating expired ids array and removing #{next_expired_id_to_verify}"
      all_expired_ids.delete(next_expired_id_to_verify)
      Rails.cache.write(["crawl/#{next_crawl_to_process}/expired_ids"], all_expired_ids) 
    
      new_expired_ids_rotation = all_expired_ids.rotate
      Rails.cache.write(["crawl/#{next_crawl_to_process}/expired_ids"], new_expired_ids_rotation)
    
      batch = Sidekiq::Batch.new
      batch.on(:complete, VerifyNamecheap)
      batch.jobs do
        puts "VerifyNamecheap: about to verify domain for crawl #{next_crawl_to_process} with id #{next_expired_id_to_verify}"
        # VerifyNamecheap.delay.perform(next_expired_id_to_verify)
        VerifyNamecheap.perform_async(next_expired_id_to_verify)
      end

    else
      puts "there are no expired domains to be verified for this crawl #{next_crawl_to_process}"
      new_expired_rotation = expired_rotation.rotate
      Rails.cache.write(['expired_rotation'], new_expired_rotation)
      if expired_rotation.count > 1
        puts "VerifyNamecheap: calling start method there are other calls in the rotation"
        VerifyNamecheap.delay(:queue => 'verify_domains').start
      end
    end
  end
  
  def self.moz(url)
    access_id = "member-8967f7dff3"
    secret_key = "8b98d4acd435d50482ebeded953e2331"
    expires = Time.now.to_i + 300
    string_to_sign = "#{access_id}\n#{expires}"
    binary_signature = OpenSSL::HMAC.digest('sha1', secret_key, string_to_sign)
    url_safe_signature = CGI::escape(Base64.encode64(binary_signature).chomp)
    response = Unirest.get "http://lsapi.seomoz.com/linkscape/url-metrics/#{url}/?AccessID=#{access_id}&Expires=#{expires}&Signature=#{url_safe_signature}"
    return JSON.parse response.raw_body
  end
  
  
end