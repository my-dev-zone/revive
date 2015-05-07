class DashboardController < ApplicationController
  before_filter :authorize

  def index
    if params['reactivate'] == 'true'
      redirect_to reactivate_path
    else
      @dashboard = current_user.user_dashboard
      @domains = Page.find(@dashboard.top_domains)
    end

  end
end
