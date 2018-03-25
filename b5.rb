VERSION = "Version 1.4.1"
puts( "BitBank BaiBai Bot (b5) " + VERSION)

require 'pp'
require 'date'
require 'io/console'
require 'yaml'

require 'ruby_bitbankcc'

# Bitbankccクラスにメソッドを追加する
class Bitbankcc
	def initRandom()
		@random = Random.new
	end
	def randomWait()
		st=1.0
		ed=3.0
		sleep(@random.rand(ed-st)+st) #2〜5秒待つ
	end

	#################################
	# すべての注文が無くなるまで待つ
	#################################
	def waitAllOrder(iDisp,iPair)
		while(true)
			print(iDisp)
			randomWait()
			orderInfoGet = JSON.parse(read_active_orders(iPair))
			if orderInfoGet["success"]==1 then
				# APIアクセス成功

				# 複数の注文情報の中から、今注文した注文情報を探す
				found = false # 注文情報を発見したか？
				for oneOrderInfoGet in orderInfoGet["data"]["orders"]
					if oneOrderInfoGet["pair"] == iPair then
						if oneOrderInfoGet["status"] != "FULLY_FILLED" then
							found = true # 注文情報を発見した
						end
					end
				end
				if not found then
					# APIアクセスに成功したが、注文がなくなったら確定とみなす
					return
				end
			#else
				# APIアクセス失敗→リトライ
			end
		end
	end
end

class OnePairBaiBai
	# BitBank.cc で取り扱っているコインペアの一覧
	BBCC_COIN_PAIR_NAMES = ["btc_jpy", "xrp_jpy", "ltc_btc", "eth_btc", "mona_jpy", "mona_btc", "bcc_jpy", "bcc_btc"]

	module StatusValues
		INITSTATUS		= 0	 # 初期状態
		GET_MYAMOUT		= 1  # 残高取得中
		GET_PRICE		= 2  # 現在価格取得
		CALC_BUYPRICE	= 3  # 購入価格計算
		CALC_BUYAMOUNT	= 4	 # 購入数量計算
		ORDER_BUY		= 5  # 発注(購入)
		WAIT_BUY		= 6  # 購入約定待ち
		CALC_SELLPRICE	= 7  # 販売価格計算
		CALC_SELLAMOUNT	= 8	 # 販売数量計算
		ORDER_SELL		= 9	 # 発注(販売)
		WAIT_SELL		= 10 # 販売約定待ち
		CANSEL_BUYORDER = 11 # 購入注文中断
	end
	class Status
		@@STATUS_NAMES = {
			StatusValues::INITSTATUS		=> "初期状態" ,
			StatusValues::GET_MYAMOUT		=> "残高取得中" ,
			StatusValues::GET_PRICE			=> "現在価格取得" ,
			StatusValues::CALC_BUYPRICE		=> "購入価格計算" ,
			StatusValues::CALC_BUYAMOUNT	=> "購入数量計算" ,
			StatusValues::ORDER_BUY			=> "発注(購入)" ,
			StatusValues::WAIT_BUY			=> "購入約定待ち" ,
			StatusValues::CALC_SELLPRICE	=> "販売価格計算" ,
			StatusValues::CALC_SELLAMOUNT	=> "販売数量計算" ,
			StatusValues::ORDER_SELL		=> "発注(販売)" ,
			StatusValues::WAIT_SELL			=> "販売約定待ち" ,
			StatusValues::CANSEL_BUYORDER	=> "購入注文中断" ,
		}
		def initialize()
			@currentStatus = StatusValues::INITSTATUS
		end
		def next()
			case @currentStatus
			when StatusValues::INITSTATUS			# 初期状態
				@currentStatus=StatusValues::GET_MYAMOUT
			when StatusValues::GET_MYAMOUT			# 残高取得中
				@currentStatus=StatusValues::GET_PRICE
			when StatusValues::GET_PRICE			# 現在価格取得
				@currentStatus=StatusValues::CALC_BUYPRICE
			when StatusValues::CALC_BUYPRICE		# 購入価格計算
				@currentStatus=StatusValues::CALC_BUYAMOUNT
			when StatusValues::CALC_BUYAMOUNT		# 購入数量計算
				@currentStatus=StatusValues::ORDER_BUY
			when StatusValues::ORDER_BUY			# 発注(購入)
				@currentStatus=StatusValues::WAIT_BUY
			when StatusValues::WAIT_BUY				# 購入約定待ち
				@currentStatus=StatusValues::CALC_SELLPRICE
			when StatusValues::CALC_SELLPRICE		# 販売価格計算
				@currentStatus=StatusValues::CALC_SELLAMOUNT
			when StatusValues::CALC_SELLAMOUNT		# 販売数量計算
				@currentStatus=StatusValues::ORDER_SELL
			when StatusValues::ORDER_SELL			# 発注(販売)
				@currentStatus=StatusValues::WAIT_SELL
			when StatusValues::WAIT_SELL			# 販売約定待ち
				@currentStatus=StatusValues::GET_MYAMOUT
			when StatusValues::CANSEL_BUYORDER		# 購入注文中断
				@currentStatus=StatusValues::GET_MYAMOUT
			else
				@currentStatus=StatusValues::INITSTATUS
			end
		end
		def setCurrentStatus(iNewStatus)
			@currentStatus = iNewStatus
		end
		def getCurrentStatus()
			return @currentStatus
		end
		def to_s
			return @@STATUS_NAMES[@currentStatus]
		end
	end

	# コンストラクタ
	def initialize(iTargetPair,iBbcc)

		# 引数で指定されたコインペアが存在するかチェック
		if not BBCC_COIN_PAIR_NAMES.include?(iTargetPair) then
			raise ArgumentError("No CoinPair")
		end

		# 引数で指定されたコインペアをクラス変数に保存
		@targetPair = iTargetPair

		# 引数で指定されたBitbankccクラスを記憶
		@bbcc = iBbcc

		# 現在の処理の状態を初期化
		@currentStatus = Status.new()

		# 最大購入待ち回数
		@buyOrderWaitMaxRetry = 10

	end

	# このインスタンスのターゲットペア名を返す
	def getTargetPair
		return @targetPair
	end

	# 現在の状態に応じた処理を実行する
	def doBaibai(iDisp,iWaitOrderDisp)
		case @currentStatus.getCurrentStatus()
		when StatusValues::INITSTATUS			# 初期状態
			# @@@@@ puts("すべての注文が無くなるまで待つ")
			# @@@@@ bbcc.waitAllOrder("待",targetPair)
			# @@@@@ puts("すべての注文が無くなりました!")
			@currentStatus.next()
		when StatusValues::GET_MYAMOUT			# 残高取得中
			getMyAmout(iDisp)
		when StatusValues::GET_PRICE			# 現在価格取得
			getPrice(iDisp)
		when StatusValues::CALC_BUYPRICE		# 購入価格計算
			calcBuyPrice(iDisp)
		when StatusValues::CALC_BUYAMOUNT		# 購入数量計算
			calcBuyAmount(iDisp)
		when StatusValues::ORDER_BUY			# 発注(購入)
			orderBuy(iDisp)
		when StatusValues::WAIT_BUY				# 購入約定待ち
			waitOrder(iDisp,iWaitOrderDisp,@myBuyOrderInfo)
		when StatusValues::CALC_SELLPRICE		# 販売価格計算
			calcSellPrice(iDisp)
		when StatusValues::CALC_SELLAMOUNT		# 販売数量計算
			calcSellAmount(iDisp)
		when StatusValues::ORDER_SELL			# 発注(販売)
			orderSell(iDisp)
		when StatusValues::WAIT_SELL			# 販売約定待ち
			waitOrder(iDisp,iWaitOrderDisp,@mySellOrderInfo)
		when StatusValues::CANSEL_BUYORDER		# 購入注文中断
			cancelOrder(iDisp,@myBuyOrderInfo)
		else
			@currentStatus.setCurrentStatus(StatusValues::INITSTATUS)
		end
	end

	#################
	# 残高情報を取得
	#################
	def getMyAmout(iDisp)
		print( DateTime.now ) if iDisp # 現在日時表示
		print(" " + @targetPair) if iDisp # ペア名表示
		print(" " + "残高情報取得") if iDisp
		@bbcc.randomWait()

		begin
			balance = JSON.parse(@bbcc.read_balance())
			if balance["success"]!=1 then
				puts(" 失敗:" + balance["data"]["code"].to_s + "\r\n") if iDisp
				return
			end
		rescue => exception
			puts(" 失敗:" + exception.to_s + "\r\n") if iDisp
			return
		end

		# 通貨ごとに残高情報をamoutに入れる
		# たとえばamout['jpy']['free_amount']ってやれば、JPYの（使用可能)残高がわかる、二次元ハッシュを用意
		@amount = Hash.new { |h,k| h[k] = {} }
		for oneAsset in balance["data"]["assets"]
			# 通貨名を取り出す
			currency_name = oneAsset["asset"]
			# 通貨名以外の情報をamoutに格納する
			oneAsset.each do |key,val|
				if key!="asset" then
					@amount[currency_name][key] = val
				end
			end
		end

		#正常終了したので、次の状態へ
		@currentStatus.next()
		puts(" 成功" + "\r\n") if iDisp
	end

	###################
	# 現在の価格を取得
	###################
	def getPrice(iDisp)
		# たとえばamout['jpy']['free_amount']ってやれば、JPYの（使用可能)残高がわかる、二次元ハッシュを用意
		@coinPrice = {} #Hash.new { |h,k| h[k] = {} }
		print( DateTime.now ) if iDisp # 現在日時表示
		print(" " + @targetPair) if iDisp # ペア名表示
		print(" " + "価格情報取得") if iDisp
		@bbcc.randomWait()

		begin
			oneCoinPrice = JSON.parse(@bbcc.read_ticker(@targetPair))
			if oneCoinPrice["success"]!=1 then
				puts(" 失敗:" + oneCoinPrice["data"]["code".to_s] + "\r\n") if iDisp
				return
			end
		rescue => exception
			puts(" 失敗:" + exception.to_s + "\r\n") if iDisp
			return
		end
			
		# その通貨の価格情報をcoinPriceに格納する
		oneCoinPrice["data"].each do |key,val|
			if key!="success" then
				@coinPrice[key] = val
			end
		end

		#正常終了したので、次の状態へ
		@currentStatus.next()
		puts(" 成功" + "\r\n") if iDisp
	end

	#############################
	# 購入価格を計算して決定する
	#############################
	def calcBuyPrice(iDisp)
		# print( DateTime.now ) if iDisp # 現在日時表示
		# print(" " + @targetPair) if iDisp # ペア名表示
		# print(" " + "購入価格計算") if iDisp

		# 購入価格を、現在の板の購入価格にする
		@targetBuyPrice = @coinPrice["buy"].to_f
		# print(" " + @targetBuyPrice.to_s) if iDisp

		#正常終了したので、次の状態へ
		@currentStatus.next()
		# puts(" 成功" + "\r\n") if iDisp
		calcBuyAmount(iDisp)
	end

	#############################
	# 購入数量を計算して決定する
	#############################
	def calcBuyAmount(iDisp)
		# print( DateTime.now ) if iDisp # 現在日時表示
		# print(" " + @targetPair) if iDisp # ペア名表示
		# print(" " + "購入数量計算") if iDisp

		# 購入数量を、現在の残高から計算する
		case @targetPair
		when "btc_jpy"
			@targetBuyAmount = 0.010 # 一万円くらい
		when "xrp_jpy"
			@targetBuyAmount = 200 # 一万円くらい
		when "ltc_btc"
			@targetBuyAmount = 0.5555 # 一万円くらい
		when "eth_btc"
			@targetBuyAmount = 0.1666 # 一万円くらい
		when "mona_jpy"
			@targetBuyAmount = 25.5555 # 一万円くらい
		when "mona_btc"
			@targetBuyAmount = 25.5555 # 一万円くらい
		when "bcc_jpy"
			@targetBuyAmount = 0.0999 # 一万円くらい
		when "bcc_btc"
			@targetBuyAmount = 0.0999 # 一万円くらい
		else
			@targetBuyAmount = 0 # 買わない
		end
		# print(" " + @targetBuyAmount.to_s) if iDisp

		#正常終了したので、次の状態へ
		@currentStatus.next()
		# puts(" 成功" + "\r\n") if iDisp
		orderBuy(iDisp)
	end

	###########################
	# 注文(購入)する
	###########################
	def orderBuy(iDisp)
		print( DateTime.now ) if iDisp # 現在日時表示
		print(" " + @targetPair) if iDisp # ペア名表示
		print(" " + "購入注文送信") if iDisp
		@bbcc.randomWait()

		begin
			buyOrderInfo = JSON.parse(@bbcc.create_order(@targetPair, @targetBuyAmount, @targetBuyPrice, "buy", "limit"))
			if buyOrderInfo["success"]!=1 then
				puts(" 失敗:" + buyOrderInfo["data"]["code"].to_s + "\r\n") if iDisp
				errcode = buyOrderInfo["data"]["code"]
				errcode = errcode.to_i
				if errcode > 60000 then
					@currentStatus.setCurrentStatus(StatusValues::GET_PRICE)
				end
				return
			end
		rescue => exception
			puts(" 失敗:" + exception.to_s + "\r\n") if iDisp
			return
		end

		# その通貨の注文情報をmyOrderInfoに格納する
		@myBuyOrderInfo = {} # Hash.new { |h,k| h[k] = {} }
		buyOrderInfo["data"].each do |key,val|
			if key!="success" then
				@myBuyOrderInfo[key] = val
			end
		end

		# 約定待リトライカウンタ初期化
		@myBuyOrderWaitCount = 0

		#正常終了したので、次の状態へ
		@currentStatus.next()
		puts(" 成功 数量:" + @targetBuyAmount.to_s + " 金額:" + @targetBuyPrice.to_s + "\r\n") if iDisp
	end

	########################################
	# 注文が確定するまで待つ(注文情報を確認)
	########################################
	def waitOrder(iDisp,iWaitOrdeDisp,iOrder)
		dispStr = ""
		dispStr = dispStr + DateTime.now.to_s # print( DateTime.now ) if iDisp # 現在日時表示
		dispStr = dispStr + " " + @targetPair.to_s # print(" " + @targetPair) if iDisp # ペア名表示
		dispStr = dispStr + " " + "注文完了待機" # print(" " + "注文完了待機") if iDisp

		side = iOrder["side"]
		if side == "buy" then
			if @myBuyOrderWaitCount>@buyOrderWaitMaxRetry then 
				@currentStatus.setCurrentStatus(StatusValues::CANSEL_BUYORDER)
				dispStr = dispStr + " " + "失敗:リトライアウト" + "\r\n"
				puts(dispStr) if iDisp
				return
			end
			@myBuyOrderWaitCount = @myBuyOrderWaitCount + 1
		end

		@bbcc.randomWait()

		begin
			orderInfoGet = JSON.parse(@bbcc.read_active_orders(@targetPair))
			if orderInfoGet["success"]!=1 then
				dispStr = dispStr + " " + "失敗:" + orderInfoGet["data"]["code"].to_s + "\r\n" # puts(" 失敗:" + orderInfoGet["data"]["code"].to_s + "\r\n") if iDisp
				puts(dispStr) if iDisp
				return
			end
		rescue => exception
			dispStr = dispStr + " " + "失敗:" + exception.to_s + "\r\n" # puts(" 失敗:" + exception.to_s + "\r\n") if iDisp
			puts(dispStr) if iDisp
			return
		end
		# 複数の注文情報の中から、今注文した注文情報を探す
		found = false # 注文情報を発見したか？
		for oneOrderInfoGet in orderInfoGet["data"]["orders"]
			if oneOrderInfoGet["order_id"] == iOrder["order_id"] then
				if oneOrderInfoGet["pair"] == iOrder["pair"] then
					found = true # 注文情報を発見した
					if oneOrderInfoGet["status"] == "FULLY_FILLED" then
						#正常終了したので、次の状態へ
						@currentStatus.next()
						dispStr = dispStr + " " + "成功 約定した。" + "\r\n" # puts(" 成功。約定した。" + "\r\n") if iDisp
						puts(dispStr) if iDisp
						return
					end
				end
			end
		end
		# 注文なくなった？
		if not found then
			# APIアクセスに成功したが、注文がなくなったら確定とみなす
			#正常終了したので、次の状態へ
			@currentStatus.next()
			dispStr = dispStr + " " + "成功 約定した。" + "\r\n" # puts(" 成功。約定した。" + "\r\n") if iDisp
			puts(dispStr) if iDisp
			return
		end
		# まだ注文が約定していない
		dispStr = dispStr + " " + "成功" + "\r\n" # puts(" 成功" + "\r\n") if iDisp
		puts(dispStr) if (iDisp && iWaitOrdeDisp)
	end

	#############################
	# 販売価格を計算して決定する
	#############################
	def calcSellPrice(iDisp)
		# print( DateTime.now ) if iDisp # 現在日時表示
		# print(" " + @targetPair) if iDisp # ペア名表示
		# print(" " + "販売価格計算") if iDisp

		# 販売価格を、購入価格の1.001倍にする
		@targetSellPrice = @targetBuyPrice.to_f * 1.001
		# print(" " + @targetSellPrice.to_s) if iDisp

		#正常終了したので、次の状態へ
		@currentStatus.next()
		# puts(" 成功" + "\r\n") if iDisp
		calcSellAmount(iDisp)
	end

	#############################
	# 販売数量を計算して決定する
	#############################
	def calcSellAmount(iDisp)
		# print( DateTime.now ) if iDisp # 現在日時表示
		# print(" " + @targetPair) if iDisp # ペア名表示
		# print(" " + "販売数量計算") if iDisp

		# 販売数量を、購入数量と同じにする。（買った分を売る）
		@targetSellAmount = @targetBuyAmount
		# print(" " + @targetSellAmount.to_s) if iDisp

		#正常終了したので、次の状態へ
		@currentStatus.next()
		# puts(" 成功" + "\r\n") if iDisp
		orderSell(iDisp)
	end

	###########################
	# 注文(販売)する
	###########################
	def orderSell(iDisp)
		print( DateTime.now ) if iDisp # 現在日時表示
		print(" " + @targetPair) if iDisp # ペア名表示
		print(" " + "販売注文送信") if iDisp
		@bbcc.randomWait()

		begin
			sellOrderInfo = JSON.parse(@bbcc.create_order(@targetPair, @targetSellAmount, @targetSellPrice, "sell", "limit"))
			if sellOrderInfo["success"]!=1 then
				puts(" 失敗:" + sellOrderInfo["data"]["code"].to_s + "\r\n") if iDisp
				errcode = sellOrderInfo["data"]["code"]
				errcode = errcode.to_i
				if errcode > 60000 then
					@currentStatus.setCurrentStatus(StatusValues::GET_PRICE)
				end
				return
			end
		rescue => exception
			puts(" 失敗:" + exception.to_s + "\r\n") if iDisp
			return
		end

		# その通貨の注文情報をmyOrderInfoに格納する
		@mySellOrderInfo = {} # Hash.new { |h,k| h[k] = {} }
		sellOrderInfo["data"].each do |key,val|
			if key!="success" then
				@mySellOrderInfo[key] = val
			end
		end

		# 約定待リトライカウンタ初期化
		@mySellOrderWaitCount = 0

		#正常終了したので、次の状態へ
		@currentStatus.next()
		puts(" 成功 数量:" + @targetSellAmount.to_s + " 金額:" + @targetSellPrice.to_s + "\r\n") if iDisp
	end

	#################
	# 注文を取り消す
	#################
	def cancelOrder(iDisp,iOrder)
		dispStr = ""
		dispStr = dispStr + DateTime.now.to_s
		dispStr = dispStr + " " + @targetPair.to_s
		dispStr = dispStr + " " + "注文取り消し"
		@bbcc.randomWait()

		begin
			cancelOrderInfo = JSON.parse(@bbcc.cancel_order(@targetPair, iOrder['order_id']))
			if cancelOrderInfo["success"]!=1 then
				dispStr = dispStr + " " + "失敗:" + cancelOrderInfo["data"]["code"].to_s + "\r\n"
				errcode = cancelOrderInfo["data"]["code"]
				errcode = errcode.to_i
				if errcode > 50000 then
					@currentStatus.setCurrentStatus(StatusValues::GET_PRICE)
				end
				puts(dispStr) if iDisp
				@currentStatus.next()
				return
			end
		rescue => exception
			dispStr = dispStr + " " + "失敗:" + exception.to_s + "\r\n" # puts(" 失敗:" + exception.to_s + "\r\n") if iDisp
			puts(dispStr) if iDisp
			return
		end

		#正常終了したので、次の状態へ
		@currentStatus.next()
		dispStr = dispStr + " " + "成功 取り消しした。" + "\r\n" # puts(" 成功。約定した。" + "\r\n") if iDisp
		puts(dispStr) if iDisp
		return
	end

end

configAPIKEY = YAML.load_file("apikey.yaml")
bbcc = Bitbankcc.new(configAPIKEY["apikey"],configAPIKEY["seckey"])
bbcc.initRandom()

# 売買を行うものを配列baibaisに格納
baibais = [] # 空の配列を作成

#for pairName in OnePairBaiBai::BBCC_COIN_PAIR_NAMES do
for pairName in ["btc_jpy", "btc_jpy", "btc_jpy", "ltc_btc", "eth_btc", "mona_jpy", "mona_btc"] do
#for pairName in ["btc_jpy"] do
		baibais.push(OnePairBaiBai.new(pairName,bbcc))
end

baibaiDisp = true
waitOrderDisp = false
commandmode = false
runningmode = true

myBaiBaiThread = Thread.start {
	while(true)
		for oneBaibai in baibais do
			oneBaibai.doBaibai(baibaiDisp,waitOrderDisp) if runningmode
		end
	end
}

loop do
	begin
		$stdin.raw do |io|
			loop do
				ch = io.readbyte
				exit 0 if ch==3 # CTRL+Cが押されたらプログラム終了

				# 何かキーが押されたので、コマンドモードへ。
				break # exit loop
			end
		end
	rescue Exception => e
		puts "何か問題が発生しました。"
		p e
	end

	# コマンドモード
	commandmode = true
	runningmode = false
	puts("\r\n処理中断中・・・")
	sleep(5)
	while(commandmode)
		puts "コマンドを入力してください。(gotobaibaiで実行に戻る)"
		inputcommand = gets.to_s.chomp
		case inputcommand
		when "gotobaibai"
			puts "継続実行開始"
			commandmode = false
			runningmode = true
		when "add btc_jpy"
			baibais.push(OnePairBaiBai.new("btc_jpy",bbcc))
			puts("追加しました。")			
		else
			begin
				eval(inputcommand)
			rescue Exception => e
				puts "何か問題が発生しました。"
				p e
			end
		end
	end
end
