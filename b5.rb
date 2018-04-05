VERSION = "Version 1.4.21"
PROGRAMNAME = "BitBank BaiBai Bot (b5) "
puts( PROGRAMNAME + VERSION )

require 'pp'
require 'date'
require 'io/console'
require 'yaml'
require 'slack/incoming/webhooks'
require 'logger'
require 'slack-ruby-bot'

require 'ruby_bitbankcc'

$end_request = false

# Bitbankccクラスにメソッドを追加する
class Bitbankcc
	def initRandom()
		@random = Random.new
	end
	def randomWait()
		st=0.6
		ed=2.9
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

class Trend
	def initialize(iPair)
		@pair = iPair
		@price_history = []
		@delta = 0
		@old_price = 0
	end
	def add_price_info(iCoinPriceInfo)
		new_price = iCoinPriceInfo['last'].to_f
		if @old_price == new_price then
			@delta = 0
			return @delta
		end
		@price_history.push ( new_price )
		@old_price = new_price
		if @price_history.size == 1 then
			@delta = 0
		elsif @price_history.size == 2 then
			@delta = 0
		else
			# @price_history.size==3
			d1 = @price_history[1] - @price_history[0]
			d2 = @price_history[2] - @price_history[1]
			if d2<=0 then
				@delta = 0
			elsif d1>0 and d2>0 then
				@delta = d1 + d2
			elsif d1<0 and d2>0 then
				@delta = d1 + d2
			end
			@price_history.shift # del [0]
		end
		return @delta
	end
	def get_trend
		return @delta
	end
end

class OnePairBaiBai
	# BitBank.cc で取り扱っているコインペアの一覧
	BBCC_COIN_PAIR_NAMES = ["btc_jpy", "xrp_jpy", "ltc_btc", "eth_btc", "mona_jpy", "mona_btc", "bcc_jpy", "bcc_btc"]

	# 全体の利益
	@@totalProfits = { "btc" => 0, "jpy" => 0 }

	# トレンドを初期化
	@@trend = {}

	# 一度に購入する最大金額
	@@amountJPYtoPurchaseAtOneTime = 10000.0 # 一万円分
	def self.amountJPYtoPurchaseAtOneTime
		@@amountJPYtoPurchaseAtOneTime
	  end
	def self.amountJPYtoPurchaseAtOneTime=(newValue)
		@@amountJPYtoPurchaseAtOneTime = newValue
	end

	@@amountBTCtoPurchaseAtOneTime = 0.01 # 1BTC=100万円として、一万円分
	def self.amountBTCtoPurchaseAtOneTime
		@@amountBTCtoPurchaseAtOneTime
	  end
	def self.amountBTCtoPurchaseAtOneTime=(newValue)
		@@amountBTCtoPurchaseAtOneTime = newValue
	end

	# 販売する価格を、購入価格の何倍にするか？
	@@magnification = 1.0005 # 10000円で買って10005円で売る。5円の利益。
	def self.magnification
		@@magnification
	end
	def self.magnification=(newValue)
		@@magnification = newValue
	end

	module StatusValues
		INITSTATUS		 = 0	 # 初期状態
		GET_MYAMOUT		 = 1  # 残高取得中
		GET_PRICE		 = 2  # 現在価格取得
		CALC_BUYPRICE	 = 3  # 購入価格計算
		CALC_BUYAMOUNT	 = 4	 # 購入数量計算
		ORDER_BUY		 = 5  # 発注(購入)
		WAIT_BUY		 = 6  # 購入約定待ち
		CALC_SELLPRICE	 = 7  # 販売価格計算
		CALC_SELLAMOUNT	 = 8	 # 販売数量計算
		ORDER_SELL		 = 9	 # 発注(販売)
		WAIT_SELL		 = 10 # 販売約定待ち
		CANSEL_BUYORDER  = 11 # 購入注文中断
		CANSEL_SELLORDER = 12 # 購入注文中断
		DISP_PROFITS	 = 13 # 利益表示
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
			StatusValues::CANSEL_SELLORDER	=> "販売注文中断" ,
			StatusValues::DISP_PROFITS		=> "利益表示" ,
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
				@currentStatus=StatusValues::DISP_PROFITS
			when StatusValues::DISP_PROFITS			# 利益表示
				@currentStatus=StatusValues::GET_MYAMOUT
			when StatusValues::CANSEL_BUYORDER		# 購入注文中断
				@currentStatus=StatusValues::GET_MYAMOUT
			when StatusValues::CANSEL_SELLORDER		# 販売注文中断
				@currentStatus=StatusValues::CALC_SELLPRICE
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
	def initialize(iTargetPair,iBbcc,iLog)

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

		# 最大販売待ち回数
		@sellOrderWaitMaxRetry = 10

		# ログクラスを保存
		@@log = iLog

		# 設定ファイル読み込み
		readSetting()

		# このコインペアでのインスタンス生成がはじめてなら、トレンドインスタンスを作成する
		if not @@trend[@targetPair] then
			@@trend[@targetPair] = Trend.new(@targetPair)
		end
	end

	def readSetting
		setting = YAML.load_file("setting.yaml")
		@@amountJPYtoPurchaseAtOneTime	= setting["amountJPYtoPurchaseAtOneTime"].to_f
		@@amountBTCtoPurchaseAtOneTime	= setting["amountBTCtoPurchaseAtOneTime"].to_f
		@@magnification					= setting["magnification"].to_f
		@buyOrderWaitMaxRetry			= setting["buyOrderWaitMaxRetry"].to_i
		@sellOrderWaitMaxRetry			= setting["sellOrderWaitMaxRetry"].to_i
		@@slackUse = setting["slack"]["use"]
		if @@slackUse then
			@@slack = Slack::Incoming::Webhooks.new setting["slack"]["webhookURL"]
		end
	end

	# slack通知を送信する
	def self.slackPost(iMsg)
		if @@slackUse then
			@@slack.post iMsg
		end
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
		when StatusValues::DISP_PROFITS			# 利益表示
			dispProfits(iDisp)
		when StatusValues::CANSEL_BUYORDER		# 購入注文中断
			cancelOrder(iDisp,@myBuyOrderInfo)
		when StatusValues::CANSEL_SELLORDER		# 販売注文中断
			cancelOrder(iDisp,@mySellOrderInfo)
		else
			@currentStatus.setCurrentStatus(StatusValues::INITSTATUS)
		end
	end

	#################
	# 残高情報を取得
	#################
	def getMyAmout(iDisp)
		print( DateTime.now ) if iDisp # 現在日時表示
		print(" " + self.object_id.to_s) # オブジェクトIDを表示
		print(" " + @targetPair) if iDisp # ペア名表示
		print(" " + "残高情報取得") if iDisp
		@@log.debug(self.object_id,self.class.name,__method__,@targetPair)
		@bbcc.randomWait()

		begin
			balance = JSON.parse(@bbcc.read_balance())
			if balance["success"]!=1 then
				errstr = "失敗:" + balance["data"]["code"].to_s
				@@log.error(self.object_id,self.class.name,__method__,errstr)
				puts(" " + errstr + "\r\n") if iDisp
				return
			end
		rescue => exception
			@@log.fatal(self.object_id,self.class.name,__method__,exception.to_s)
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
		print(" " + self.object_id.to_s) # オブジェクトIDを表示
		print(" " + @targetPair) if iDisp # ペア名表示
		print(" " + "価格情報取得") if iDisp
		@@log.debug(self.object_id,self.class.name,__method__,@targetPair)
		@bbcc.randomWait()

		begin
			oneCoinPrice = JSON.parse(@bbcc.read_ticker(@targetPair))
			if oneCoinPrice["success"]!=1 then
				errstr = "失敗:" + oneCoinPrice["data"]["code"].to_s
				@@log.error(self.object_id,self.class.name,__method__,errstr)
				puts(" " + errstr + "\r\n") if iDisp
				return
			end
		rescue => exception
			@@log.fatal(self.object_id,self.class.name,__method__,exception.to_s)
			puts(" 失敗:" + exception.to_s + "\r\n") if iDisp
			return
		end
			
		# その通貨の価格情報をcoinPriceに格納する
		oneCoinPrice["data"].each do |key,val|
			if key!="success" then
				@coinPrice[key] = val
			end
		end

		# 現在の価格情報を傾向管理クラスに渡す
		if @@trend[@targetPair].add_price_info(@coinPrice)<=0 then
			# 価格が降下しているので、購入しない＝価格取得をやり直す
			puts(" 価格降下中" + "\r\n") if iDisp
			return
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
		# print(" " + self.object_id.to_s) # オブジェクトIDを表示
		# print(" " + @targetPair) if iDisp # ペア名表示
		# print(" " + "購入価格計算") if iDisp

		# 購入価格を、現在の板の購入価格にする
		@targetBuyPrice = @coinPrice["buy"].to_f
		if ((Time.now.to_f * 1000).to_i % 10 >4) then
			@targetBuyPrice = @targetBuyPrice * 1.0005
		else
			@targetBuyPrice = @targetBuyPrice / 1.001
		end
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
		# print(" " + self.object_id.to_s) # オブジェクトIDを表示
		# print(" " + @targetPair) if iDisp # ペア名表示
		# print(" " + "購入数量計算") if iDisp

		# 購入可能金額
		case @targetPair
		when "btc_jpy","xrp_jpy","mona_jpy","bcc_jpy"
			freeamount = @amount['jpy']['free_amount'].to_f
			tukau = @@amountJPYtoPurchaseAtOneTime.to_f
		when "ltc_btc","eth_btc","mona_btc","bcc_btc"
			freeamount = @amount['btc']['free_amount'].to_f
			tukau = @@amountBTCtoPurchaseAtOneTime.to_f
		else
			freeamount = 0.0 # 買わない
			tukau = 0.0 # 買わない
		end
		# 使用予定金額が手持金を超えていたら、手持ち金を使用予定金額を使う。
		#if tukau>freeamount then
		#	tukau = freeamount
		#end

		# 購入数量＝単位購入金額(JPY)÷購入予定価格(BTC)で計算する。
		@targetBuyAmount = tukau.to_f / @targetBuyPrice.to_f # 一万円分

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
		print(" " + self.object_id.to_s) # オブジェクトIDを表示
		print(" " + @targetPair) if iDisp # ペア名表示
		print(" " + "購入注文送信") if iDisp
		@bbcc.randomWait()

		begin
			buyOrderInfo = JSON.parse(@bbcc.create_order(@targetPair, @targetBuyAmount, @targetBuyPrice, "buy", "limit"))
			if buyOrderInfo["success"]!=1 then
				errstr = "失敗:" + buyOrderInfo["data"]["code"].to_s
				@@log.error(self.object_id,self.class.name,__method__,errstr)
				puts(" " + errstr + "\r\n") if iDisp
				errcode = buyOrderInfo["data"]["code"]
				errcode = errcode.to_i
				if errcode > 60000 then
					# @@log.debug(self.object_id,self.class.name,__method__,"GET_PRICEへ移動")
					@currentStatus.setCurrentStatus(StatusValues::GET_PRICE)
				end
				return
			end
		rescue => exception
			@@log.fatal(self.object_id,self.class.name,__method__,exception.to_s)
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

		# 購入約定待リトライカウンタ初期化
		@myBuyOrderWaitCount = 0

		#正常終了したので、次の状態へ
		@currentStatus.next()
		dispmsg = "成功 数量:" + @targetBuyAmount.to_s + " 金額:" + @targetBuyPrice.to_s 
		puts(" " + dispmsg + "\r\n") if iDisp
		@@log.debug(self.object_id,self.class.name,__method__,dispmsg)
	end

	########################################
	# 注文が確定するまで待つ(注文情報を確認)
	########################################
	def waitOrder(iDisp,iWaitOrdeDisp,iOrder)
		dispStr = ""
		dispStr = dispStr + DateTime.now.to_s # print( DateTime.now ) if iDisp # 現在日時表示
		dispStr = dispStr + " " + self.object_id.to_s # print(" " + self.object_id.to_s) # オブジェクトIDを表示
		dispStr = dispStr + " " + @targetPair.to_s # print(" " + @targetPair) if iDisp # ペア名表示
		side = iOrder["side"].to_s
		dispStr = dispStr + " " + side + "注文完了待機" # print(" " + "注文完了待機") if iDisp

		if side == "buy" then
			if @myBuyOrderWaitCount>@buyOrderWaitMaxRetry then 
				@currentStatus.setCurrentStatus(StatusValues::CANSEL_BUYORDER)
				dispStr = dispStr + " " + "失敗:リトライアウト" + "\r\n"
				puts(dispStr) if (iDisp && iWaitOrdeDisp)
				return
			end
			@myBuyOrderWaitCount = @myBuyOrderWaitCount + 1
		elsif side == "sell" then
			if @mySellOrderWaitCount>@sellOrderWaitMaxRetry then 
				@currentStatus.setCurrentStatus(StatusValues::CANSEL_SELLORDER)
				dispStr = dispStr + " " + "失敗:リトライアウト" + "\r\n"
				puts(dispStr) if (iDisp && iWaitOrdeDisp)
				return
			end
			@mySellOrderWaitCount = @mySellOrderWaitCount + 1
		end

		@bbcc.randomWait()

		begin
			orderInfoGet = JSON.parse(@bbcc.read_active_orders(@targetPair))
			if orderInfoGet["success"]!=1 then
				errstr = "失敗:" + orderInfoGet["data"]["code"].to_s
				@@log.error(self.object_id,self.class.name,__method__,errstr)
				dispStr = dispStr + " " + errstr + "\r\n" # puts(" 失敗:" + orderInfoGet["data"]["code"].to_s + "\r\n") if iDisp
				puts(dispStr) if iDisp
				return
			end
		rescue => exception
			@@log.fatal(self.object_id,self.class.name,__method__,exception.to_s)
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
						@@log.debug(self.object_id,self.class.name,__method__,"約定した。FULLY_FILLED")
						return
					end
					if oneOrderInfoGet["status"] == "PARTIALLY_FILLED" then
						# 一部約定してしまったので、キャンセルしないように、リトライカウンタをリセット
						@myBuyOrderWaitCount = 0
						@mySellOrderWaitCount = 0
						# まだ注文が約定していない
						dispStr = dispStr + " " + "成功" + "\r\n" # puts(" 成功" + "\r\n") if iDisp
						puts(dispStr) if (iDisp && iWaitOrdeDisp)
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
			@@log.debug(self.object_id,self.class.name,__method__,"約定した。NO_ORDERINFO")
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
		# print(" " + self.object_id.to_s) # オブジェクトIDを表示
		# print(" " + @targetPair) if iDisp # ペア名表示
		# print(" " + "販売価格計算") if iDisp

		# 販売価格を、購入価格の1.001倍(設定ファイル)にする
		@targetSellPrice = @targetBuyPrice.to_f * @@magnification

		# 販売予定価格(購入価格の1.001倍)より、市場販売価格(の0.999倍)のほうが高ければ、市場販売価格市場販売価格(の0.999倍)にする。つまり、高く売る。
		# (販売価格 = 市場価格÷1.001 if 購入価格×1.01<市場価格÷1.01)
		market_price = @coinPrice["sell"].to_f / @@magnification
		if @targetSellPrice < market_price then		
			@targetSellPrice = market_price
			puts("販売価格を市場価格に更新:" +  + @targetSellPrice.to_s) if iDisp
		end
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
		# print(" " + self.object_id.to_s) # オブジェクトIDを表示
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
		print(" " + self.object_id.to_s) # オブジェクトIDを表示
		print(" " + @targetPair) if iDisp # ペア名表示
		print(" " + "販売注文送信") if iDisp
		@bbcc.randomWait()

		begin
			sellOrderInfo = JSON.parse(@bbcc.create_order(@targetPair, @targetSellAmount, @targetSellPrice, "sell", "limit"))
			if sellOrderInfo["success"]!=1 then
				errstr = "失敗:" + sellOrderInfo["data"]["code"].to_s
				@@log.error(self.object_id,self.class.name,__method__,errstr)
				puts(" " + errstr + "\r\n") if iDisp
				errcode = sellOrderInfo["data"]["code"]
				errcode = errcode.to_i
				if errcode > 60000 then
					# @@log.debug(self.object_id,self.class.name,__method__,"GET_PRICEへ移動")
					@currentStatus.setCurrentStatus(StatusValues::GET_PRICE)
				end
				return
			end
		rescue => exception
			@@log.fatal(self.object_id,self.class.name,__method__,exception.to_s)
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

		# 販売約定待リトライカウンタ初期化
		@mySellOrderWaitCount = 0

		#正常終了したので、次の状態へ
		@currentStatus.next()
		dispmsg = "成功 数量:" + @targetSellAmount.to_s + " 金額:" + @targetSellPrice.to_s
		puts(" " + dispmsg + "\r\n") if iDisp
		@@log.debug(self.object_id,self.class.name,__method__,dispmsg)
	end

	#################
	# 注文を取り消す
	#################
	def cancelOrder(iDisp,iOrder)
		dispStr = ""
		dispStr = dispStr + DateTime.now.to_s
		dispStr = dispStr + " " + self.object_id.to_s
		dispStr = dispStr + " " + @targetPair.to_s
		dispStr = dispStr + " " + iOrder["side"].to_s + "注文取り消し"
		@bbcc.randomWait()

		begin
			cancelOrderInfo = JSON.parse(@bbcc.cancel_order(@targetPair, iOrder['order_id']))
			if cancelOrderInfo["success"]!=1 then
				errstr = "失敗:" + cancelOrderInfo["data"]["code"].to_s
				@@log.error(self.object_id,self.class.name,__method__,errstr)

				dispStr = dispStr + " " + errstr + "\r\n"
				errcode = cancelOrderInfo["data"]["code"]
				errcode = errcode.to_i
				if errcode > 50000 then
					# 注文が存在しない or 注文キャンセルできない → リトライカウンタをリセットして購入約定待へ
					# @@log.debug(self.object_id,self.class.name,__method__,"WAIT_BUYへ移動")
					@myBuyOrderWaitCount = 0
					@mySellOrderWaitCount = 0
					@currentStatus.setCurrentStatus(StatusValues::WAIT_BUY)
				end
				puts(dispStr) if iDisp
				return
			end
		rescue => exception
			@@log.fatal(self.object_id,self.class.name,__method__,exception.to_s)
			dispStr = dispStr + " " + "失敗:" + exception.to_s + "\r\n" # puts(" 失敗:" + exception.to_s + "\r\n") if iDisp
			puts(dispStr) if iDisp
			return
		end

		#正常終了したので、次の状態へ
		@currentStatus.next()
		dispStr = dispStr + " " + "成功 取り消しした。" + "\r\n" # puts(" 成功。約定した。" + "\r\n") if iDisp
		puts(dispStr) if iDisp
		@@log.debug(self.object_id,self.class.name,__method__,"成功")
		return
	end

	###########
	# 利益表示
	###########
	def dispProfits(iDisp)
		print( DateTime.now ) if iDisp # 現在日時表示
		print(" " + self.object_id.to_s) # オブジェクトIDを表示
		print(" " + @targetPair) if iDisp # ペア名表示
		print(" " + "利益表示") if iDisp

		# 単位通貨名
		unitName = @targetPair.split("_")[1] # @targetPairを_で区切った配列のindex1(２番め)、つまり後側

		# 今回の利益を計算
		currentProfits = @mySellOrderInfo["price"].to_f * @mySellOrderInfo["start_amount"].to_f - @myBuyOrderInfo["price"].to_f * @myBuyOrderInfo["start_amount"].to_f

		# 合計利益を計算
		@@totalProfits[unitName] = @@totalProfits[unitName].to_f + currentProfits

		# 表示
		# dispStr = "今回売買:" + currentProfits.to_s + " ###合計利益:" + @@totalProfits[unitName].to_s + " " + unitName.to_s
		dispStr = "合計:" + @@totalProfits[unitName].to_s + " " + unitName.to_s + " 今回:" + currentProfits.to_s 
		print(" " + dispStr + "\r\n") if iDisp

		# ログへ記録
		@@log.info(self.object_id,self.class.name,__method__,dispStr)

		# slack 通知
		OnePairBaiBai.slackPost( dispStr )

		#正常終了したので、次の状態へ
		@currentStatus.next()
		return
	end

	###################################
	# 全利益を返すスタティックメソッド
	###################################
	def self.getTotalProfits()
		return @@totalProfits
	end

	def get_waiting_order
		case @currentStatus.getCurrentStatus()
		when StatusValues::WAIT_BUY				# 購入約定待ち
			@myBuyOrderInfo.pretty_inspect.to_s
		when StatusValues::WAIT_SELL			# 販売約定待ち
			@mySellOrderInfo.pretty_inspect.to_s
		else
			""
		end
	end
end

class MyLog < Logger
	def enable
		@enable
	end
	def enable=(newValue)
		@enable = newValue
	end
	def debug(iObjectID,iClassName,iMethodName,iMsg)
		return if !@enable
		super(iObjectID.to_s + " " + iClassName.to_s + " " + iMethodName.to_s + " " + iMsg)
	end
	def info(iObjectID,iClassName,iMethodName,iMsg)
		return if !@enable
		super(iObjectID.to_s + " " + iClassName.to_s + " " + iMethodName.to_s + " " + iMsg)
	end
	def warn(iObjectID,iClassName,iMethodName,iMsg)
		return if !@enable
		super(iObjectID.to_s + " " + iClassName.to_s + " " + iMethodName.to_s + " " + iMsg)
	end
	def error(iObjectID,iClassName,iMethodName,iMsg)
		return if !@enable
		super(iObjectID.to_s + " " + iClassName.to_s + " " + iMethodName.to_s + " " + iMsg)
	end
	def fatal(iObjectID,iClassName,iMethodName,iMsg)
		return if !@enable
		super(iObjectID.to_s + " " + iClassName.to_s + " " + iMethodName.to_s + " " + iMsg)
	end
	def unknown(iObjectID,iClassName,iMethodName,iMsg)
		return if !@enable
		super(iObjectID.to_s + " " + iClassName.to_s + " " + iMethodName.to_s + " " + iMsg)
	end
end

# 設定ファイル読み込み
setting = YAML.load_file("setting.yaml")

# ログクラスを作成
log = MyLog.new(setting["log"]["filepath"])
log.enable = setting["log"]["enable"]

log.info(self.object_id,"main","main",(PROGRAMNAME + VERSION))

# APIキーをファイルから読み込んでクラス初期化
configAPIKEY = YAML.load_file("apikey.yaml")
bbcc = Bitbankcc.new(configAPIKEY["apikey"],configAPIKEY["seckey"])
bbcc.initRandom()

# 売買を行うものをファイルから読み込む
targetbaibailist = setting["targetBaiBailist"]

# 売買を行うものを配列baibaisに格納
baibais = [] # 空の配列を作成
for pairName in targetbaibailist do
	baibais.push(OnePairBaiBai.new(pairName,bbcc,log))
end

# プログラム名をslackに表示（起動通知）
OnePairBaiBai.slackPost (PROGRAMNAME + VERSION)

baibaiDisp = true
waitOrderDisp = false
runningmode = true

myBaiBaiThread = Thread.start {
	while(true)
		for oneBaibai in baibais do
			oneBaibai.doBaibai(baibaiDisp,waitOrderDisp) if runningmode
			exit(0) if $end_request
		end
	end
}

SlackRubyBot::Client.logger.level = Logger::WARN

class Bot
	def initialize(baibais,bbcc,log)
		@baibais = baibais
		@bbcc = bbcc
		@log = log
	end

	def call(client, data)
		begin
			sendtext = ""
			inputcommand = data.text
			case inputcommand
			when "add btc_jpy"
				@baibais.push(OnePairBaiBai.new("btc_jpy",@bbcc,@log))
				sendtext ="btc_jpyを１つ追加しました。合計で" + @baibais.size.to_s + "件動作しています。"
			when "dispallprofits"
				sendtext = "利益:" + OnePairBaiBai.getTotalProfits().pretty_inspect.to_s
			when "dispwaitorders"
				sendtext = "オーダー待ちは\n"
				for oneBaibai in @baibais do
					tmp = oneBaibai.get_waiting_order
					if tmp != ""
						sendtext = sendtext + tmp + "\n"
					end
				end
				sendtext = sendtext + "・・・以上です"
			when "exitprogram"
				sendtext = "プログラムを終了します。"
				$end_request = true
			when "version"
				sendtext = PROGRAMNAME + VERSION
			when "help"
				sendtext = "add btc_jpy\ndispallprofits\ndispwaitorders\nexitprogram\nversion\nhelp"
			else
				sendtext = eval(inputcommand)
			end
		rescue Exception => e
			# log.fatal(self.object_id,"main","main",e.to_s)
			sendtext = "何か問題が発生しました。\n" + e.to_s
		end
		client.say(text: sendtext, channel: data.channel)
	end
end

server = SlackRubyBot::Server.new(
  token: setting["slack"]["botAPItoken"],
  hook_handlers: {
    message: Bot.new(baibais, bbcc, log)
  }
)
server.run
