class SessionsController < ApplicationController
  skip_before_action :authenticate!

  def new
    @users = User.all
  end

  def create
    session[:user_id] = session_params.fetch(:id)

    redirect_to users_url
  end

  private

  def session_params
    params.require(:session).permit(:id)
  end
end
