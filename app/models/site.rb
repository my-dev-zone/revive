require 'namecheap' 

class Site < ActiveRecord::Base
  belongs_to :crawl
  has_many :pages
  has_many :links
  has_one :gather_links_batch
  has_one :process_links_batch
  has_one :verify_namecheap_batch
  has_one :verify_majestic_batch
  
end
