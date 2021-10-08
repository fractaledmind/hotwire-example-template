class CardsController < ApplicationController
  def update
    @board = Board.find params[:board_id]
    @card = @board.cards.find params[:id]

    @card.update! card_params

    redirect_to board_url(@board)
  end

  private

  def card_params
    params.require(:card).permit(:row_order_position)
  end
end
