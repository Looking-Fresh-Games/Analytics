--[=[
	@class Analytics

	Author: Javi M (dig1t)

	GameAnalytics wrapper for tracking player events, purchases, and errors.
	This module will log to both GameAnalytics and Roblox Analytics.

	The API keys can be found inside game settings of your GameAnalytics game page.

	Events that happen during a mission (kills, deaths, rewards) should be
	tracked and logged after the event ends	to avoid hitting API limits.
	For example, if a player kills an enemy during a mission, the kill should be
	tracked and logged (sum of kills) at the end of the mission.

	Refer to [GameAnalytics docs](https://docs.gameanalytics.com/integrations/sdk/roblox/event-tracking) for more information and use cases.

	### Quick Start

	In order to use this module, you must first configure it with `Analytics.start()` (example: in the main server script)

	To configure Analytics.
	```lua
	local Analytics = require(ReplicatedStorage.Shared.Modules.Analytics)

	Analytics.start({
		currencies = { "Coins" },
		build = "1.0.0",
		gameKey = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
		secretKey = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
		-- secret = "ga_secret" -- You can use Roblox secrets as well
	})
	```

	Using Analytics to track events on the client:
	```lua
	-- Add a value as a tracked event
	-- This will be sent when the player leaves the game
	Analytics.addTrackedValue({
		event = "UIEvent:OpenedShop",
		value = 1
	})

	-- Log an event
	Analytics.logEvent({
		event = "ToggledMenu"
	})

	-- Add a delayed event that fires when the player leaves
	Analytics.addDelayedEvent({
		event = "UIEvent:ClaimedReward"
	})
	```

	Logging currency transactions
	```lua
	-- Log 100 coins being gained for completing FTUE
	Analytics.logResourceEvent({
		player = Player,
		eventType = "Reward",
		currency = "Coins",
		itemId = "FTUE Reward",
		flowType = "Source",
		amount = 100
	})

	-- Log 100 coins being spent in a shop
	Analytics.logPurchase({
		player = Player,
		eventType = "Shop",
		currency = "Coins",
		itemId = "Red Car",
		amount = 100
	})
	```
]=]

local AnalyticsService = game:GetService("AnalyticsService")
local HttpService = game:GetService("HttpService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local GameAnalytics = require(script.Parent.GameAnalytics)
local Promise = require(script.Parent.Promise)

local AnalyticsTypes = require(script.Types)

export type TransactionType = AnalyticsTypes.TransactionType
export type BaseEvent = AnalyticsTypes.BaseEvent
export type DimensionData = AnalyticsTypes.DimensionData
export type CustomDimensions = AnalyticsTypes.CustomDimensions
export type MarketplacePurchaseEvent = AnalyticsTypes.MarketplacePurchaseEvent
export type PurchaseEvent = AnalyticsTypes.PurchaseEvent
export type ResourceEvent = AnalyticsTypes.ResourceEvent
export type ErrorEvent = AnalyticsTypes.ErrorEvent
export type ProgressionEvent = AnalyticsTypes.ProgressionEvent
export type DimensionEvent = AnalyticsTypes.DimensionEvent
export type RemoteConfig = AnalyticsTypes.RemoteConfig
export type PsuedoPlayerData = AnalyticsTypes.PsuedoPlayerData
export type ServerPsuedoPlayer = AnalyticsTypes.ServerPsuedoPlayer
export type AnalyticsOptions = AnalyticsTypes.AnalyticsOptions
export type PromiseStatus = AnalyticsTypes.PromiseStatus
export type PromiseStatuses = AnalyticsTypes.PromiseStatuses
export type Promise<T, U> = AnalyticsTypes.Promise<T, U>
export type TeleportEvent = AnalyticsTypes.TeleportEvent

local DEFAULT_TRANSACTION_TYPE: TransactionType = "Gameplay"

local analyticsStarted: boolean = false

local cache: { string: any } = {}
local events = {} :: { [Player]: { BaseEvent } }
local trackedEvents = {}
local resourceEventTypes: { string } = {}

local configuration: {
	currencies: { string },
	build: string,
	gameKey: string,
	secretKey: string,
	customDimensions: CustomDimensions?,
	logErrors: boolean?,
	debug: boolean?,
}

local remote: RemoteEvent

local isClient: boolean = RunService:IsClient()

local Analytics = {}

if isClient then
	remote = script:WaitForChild("AnalyticsEvent")
else
	-- Prevent unwanted SDK warnings and errors from showing in production
	GameAnalytics.Logger.w = function(_, ...)
		if debug then
			warn(...)
		end
	end -- Force disable warnings
	GameAnalytics.Logger.e = function(_, ...)
		if debug then
			error(...)
		end
	end -- Force disable errors

	remote = Instance.new("RemoteEvent")
	remote.Name = "AnalyticsEvent"
	remote.Parent = script
end

local function catch(...)
	-- Do nothing
	-- This is here to prevent unhandled promise rejections
	-- You can add your own error handling when using one of the Analytics functions
	-- since they all return Promises

	if configuration.debug == true then
		warn(...)
	end
end

-- Formats an ID string to be GameAnalytics compatible
local function formatItemId(itemId: string)
	return string.gsub(itemId, "[^%a%w%-%.%()!%?]", "")
end

-- Used to safely send an event to GameAnalytics
-- without an error being thrown
function gaWrapper(fn: string, ...): Promise<any, any>
	local args = { ... }

	local promiseFunction = Promise.promisify(GameAnalytics[fn])

	return promiseFunction(GameAnalytics, unpack(args)):catch(catch)
end

-- Flush any tracked events for a player
local function flushTrackedEvents(player: Player)
	if not player or not analyticsStarted then
		return
	end

	if events[player] then
		for _, event in pairs(events[player]) do
			Analytics.logPlayerEvent({
				player = player,
				event = event.event,
				value = event.value,
			})
		end

		events[player] = nil
	end

	if trackedEvents[player] then
		for event, value in pairs(trackedEvents[player]) do
			Analytics.logPlayerEvent({
				player = player,
				event = event,
				value = value,
			})
		end

		trackedEvents[player] = nil
	end
end

-- Formats an event string to be GameAnalytics compatible
local function formatEventString(event: string): string
	-- Sanitize event string to prevent errors
	event = string.gsub(event, "[^%w%-_%.%s:]", "_")

	-- Trim trailing colon and spaces
	event = string.gsub(event, ":%s*$", "")

	return event
end

-- Available field keys for the Roblox Analytics API
local ANALYTICS_CUSTOM_FIELDS: { string } = {
	Enum.AnalyticsCustomFieldKeys.CustomField01.Name,
	Enum.AnalyticsCustomFieldKeys.CustomField02.Name,
	Enum.AnalyticsCustomFieldKeys.CustomField03.Name,
}

-- Converts a string table to Roblox Analytics custom fields
local function stringTableToRobloxCustomFields(fields: { string }?): { [string]: string }
	if not fields then
		return {}
	end

	local customFields: { [string]: string } = {}

	for index, field in fields do
		if ANALYTICS_CUSTOM_FIELDS[index] then
			customFields[ANALYTICS_CUSTOM_FIELDS[index]] = field
		end
	end

	return customFields
end

-- Extracts custom fields from an event string
-- Example: "Player:KilledZombie:Level 1" -> { CustomField01 = "KilledZombie", CustomField02 = "Level 1" }
local function getCustomFields(event: string): { [string]: string }
	-- Split the event string to assign custom fields
	local customFields: { string } = {}

	for splitIndex: number, customField: string in string.split(event, ":") do
		local currentFieldIndex = #customFields + 1

		-- Skip the first field (event name) and any fields
		-- that don't have a custom field key index (Roblox Analytics only supports 3 custom fields)
		if splitIndex == 1 or not ANALYTICS_CUSTOM_FIELDS[currentFieldIndex] then
			continue
		end

		customFields[#customFields + 1] = customField
	end

	return stringTableToRobloxCustomFields(customFields)
end

-- Grabs product info from MarketplaceService and caches it
local function getProductInfo(
	productId: number,
	infoType: Enum.InfoType?
): { Name: string, PriceInRobux: number }?
	local _infoType: Enum.InfoType = typeof(infoType) == "EnumItem" and infoType
		or Enum.InfoType.Asset
	local infoTypeName: string = _infoType.Name

	local success: boolean, result = pcall(function()
		local cacheIndex: string = `{infoTypeName}-{productId}`

		if cache[cacheIndex] then
			return cache[cacheIndex]
		end

		local productInfo: { unknown } =
			MarketplaceService:GetProductInfo(productId, _infoType)

		cache[cacheIndex] = productInfo

		return productInfo
	end)

	return success and result or nil
end

-- Starts GameAnalytics with the provided configuration
local function startGameAnalytics()
	if analyticsStarted then
		return
	end

	-- Enable any defined custom dimensions
	if configuration.customDimensions then
		local dimensions: CustomDimensions = configuration.customDimensions

		if dimensions and dimensions.dimension01 then
			GameAnalytics:configureAvailableCustomDimensions01(dimensions.dimension01)
		end

		if dimensions and dimensions.dimension02 then
			GameAnalytics:configureAvailableCustomDimensions02(dimensions.dimension02)
		end

		if dimensions and dimensions.dimension03 then
			GameAnalytics:configureAvailableCustomDimensions03(dimensions.dimension03)
		end
	end

	GameAnalytics:configureBuild(configuration.build)
	GameAnalytics:configureAvailableResourceCurrencies(configuration.currencies)
	GameAnalytics:setEnabledInfoLog(configuration.debug == true)
	GameAnalytics:setEnabledVerboseLog(configuration.debug == true)
	GameAnalytics:setEnabledDebugLog(configuration.debug == true)
	GameAnalytics:setEnabledReportErrors(
		configuration.logErrors == true or configuration.debug == true
	)
	GameAnalytics:setEnabledAutomaticSendBusinessEvents(false)
	GameAnalytics:initServer(configuration.gameKey, configuration.secretKey)
end

local function handleListeners()
	if analyticsStarted then
		return
	end

	-- Listen for player actions
	remote.OnServerEvent:Connect(function(player: Player, action: string, data: BaseEvent)
		data.player = player

		if action == "LOG_PLAYER_EVENT" then
			Analytics.logPlayerEvent(data)
		elseif action == "ADD_DELAYED_EVENT" then
			-- Logs an event to be sent once the player is leaving the game
			Analytics.addDelayedEvent(data)
		elseif action == "ADD_TRACKED_VALUE" then
			-- Adds a value to a tracked event, it will be sent once the player is leaving the game
			Analytics.addTrackedValue(data)
		elseif action == "SET_CUSTOM_DIMENSION" then
			local dimensionData: DimensionData = data :: any

			Analytics.setCustomDimension({
				player = player,
				event = dimensionData.event,
				value = dimensionData.value,
			})
		end
	end)

	MarketplaceService.PromptBundlePurchaseFinished:Connect(
		function(player: Player, bundleId: number, purchased: boolean)
			if not purchased then
				return
			end

			local productInfo = getProductInfo(bundleId, Enum.InfoType.Bundle)

			Analytics.logMarketplacePurchase({
				player = player,
				itemType = "Bundle",
				id = productInfo and productInfo.Name or bundleId,
				cartType = "PromptPurchase",
				robuxPrice = productInfo and productInfo.PriceInRobux,
			})
		end
	)

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(
		function(player: Player, gamePassId: number, purchased: boolean)
			if not purchased then
				return
			end

			local productInfo = getProductInfo(gamePassId, Enum.InfoType.GamePass)

			Analytics.logMarketplacePurchase({
				player = player,
				itemType = "GamePass",
				id = productInfo and productInfo.Name or gamePassId,
				cartType = "PromptPurchase",
				robuxPrice = productInfo and productInfo.PriceInRobux,
			})
		end
	)

	MarketplaceService.PromptProductPurchaseFinished:Connect(
		function(userId: number, productId: number, purchased: boolean)
			if not purchased then
				return
			end

			local player: Player? = Players:GetPlayerByUserId(userId)

			if not player then
				return
			end

			local productInfo = getProductInfo(productId, Enum.InfoType.Product)

			Analytics.logMarketplacePurchase({
				player = player,
				itemType = "Product",
				id = productInfo and productInfo.Name or productId,
				cartType = "PromptPurchase",
				robuxPrice = productInfo and productInfo.PriceInRobux,
			})
		end
	)

	MarketplaceService.PromptPurchaseFinished:Connect(
		function(player: Player, assetId: number, purchased: boolean)
			if not purchased then
				return
			end

			local productInfo = getProductInfo(assetId, Enum.InfoType.Asset)

			Analytics.logMarketplacePurchase({
				player = player,
				itemType = "Asset",
				id = productInfo and productInfo.Name or assetId,
				cartType = "PromptPurchase",
				robuxPrice = productInfo and productInfo.PriceInRobux,
			})
		end
	)

	MarketplaceService.PromptSubscriptionPurchaseFinished:Connect(
		function(player: Player, subscriptionId: string, didTryPurchasing: boolean)
			if not didTryPurchasing then
				return
			end

			local success, result = pcall(function()
				local cacheIndex: string = `subscription-{subscriptionId}`

				if cache[cacheIndex] then
					return cache[cacheIndex]
				end

				local productInfo =
					MarketplaceService:GetSubscriptionProductInfoAsync(subscriptionId)

				cache[cacheIndex] = productInfo

				return productInfo
			end)

			local robuxPrice = 0

			if success then
				local priceNumberString = string.match(result.DisplayPrice, "%d+%.?%d*")
				local dollarPrice = tonumber(priceNumberString or "")

				if dollarPrice ~= nil then
					-- Convert from USD to Robux using Roblox's exchange rate
					robuxPrice = ((dollarPrice * 100) / 0.7) / 0.35
				end
			end

			Analytics.logMarketplacePurchase({
				player = player,
				itemType = "Subscription",
				id = success and result.Name or subscriptionId,
				amount = robuxPrice,
				cartType = "PromptPurchase",
			})
		end
	)

	Players.PlayerAdded:Connect(function(player: Player)
		if player.FollowUserId ~= 0 then
			Analytics.logPlayerEvent({
				player = player,
				event = "FollowedPlayer",
			})
		end
	end)

	Players.PlayerRemoving:Connect(flushTrackedEvents)
end

local Validate = {}

function Validate.event(data: BaseEvent): Promise<nil, string>
	return Promise.new(function(resolve, reject)
		if not analyticsStarted then
			return reject("Analytics must be configured with Analytics.start()")
		elseif typeof(data) ~= "table" then
			-- Possibly an exploit attempt
			return reject("Invalid data")
		elseif data.event == nil then
			return reject("event is required")
		elseif typeof(data.event) ~= "string" then
			return reject("event must be a string")
		elseif data.value == nil then
			return reject("value is required")
		end

		return resolve()
	end)
end

function Validate.playerEvent(data: BaseEvent): Promise<nil, string>
	return Promise.new(function(resolve, reject)
		if not data.player then
			return reject("player is required")
		end

		return Validate.event(data):andThen(resolve):catch(reject)
	end)
end

function Validate.dimensionData(data: DimensionData): Promise<nil, string>
	return Promise.new(function(resolve, reject)
		if not data then
			return reject("data is required")
		elseif not data.player then
			return reject("player is required")
		elseif not data.event or typeof(data.event) ~= "string" then
			return reject("event is required")
		elseif data.value == nil then
			return reject("value is required")
		end

		return resolve()
	end)
end

local GA_DIMENSIONS: { string } = {
	"dimension01",
	"dimension02",
	"dimension03",
}

--[=[
	Starts the Analytics module and initializes GameAnalytics with the provided configuration.

	```lua
	local Analytics = require(ReplicatedStorage.Shared.Modules.Analytics)

	Analytics.start({
		currencies = { "Coins" },
		build = "1.0.0",
		gameKey = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
		secretKey = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
		-- secret = "ga_secret" -- You can use Roblox secrets as well
	})
	```

	@server
	@param options AnalyticsOptions
]=]
function Analytics.start(options: AnalyticsOptions)
	if analyticsStarted then
		warn("Analytics.start() - Analytics has already been started")

		return
	end

	assert(typeof(options) == "table", "Analytics.start - options is required")
	assert(options.gameKey, "Analytics.start - gameKey is required")
	assert(
		options.secret or options.secretKey,
		"Analytics.start - secret or secretKey is required"
	)
	assert(
		typeof(options.logErrors) == "boolean" or options.logErrors == nil,
		"Analytics.start - logErrors must be a boolean or nil"
	)

	-- Validate custom dimensions
	if options.customDimensions then
		assert(
			typeof(options.customDimensions) == "table",
			"Analytics.start - customDimensions must be a table"
		)

		for dimension: string?, values: { string? }? in pairs(options.customDimensions) do
			assert(
				typeof(dimension) == "string",
				"Analytics.start - dimension index must be a string"
			)
			assert(
				table.find(GA_DIMENSIONS, dimension),
				`Analytics.start - customDimensions.{dimension} is not a valid dimension`
			)
			assert(
				typeof(values) == "table",
				`Analytics.start - {dimension} must be a table`
			)

			for _, value: string? in pairs(values) do
				assert(
					typeof(value) == "string",
					`Analytics.start - customDimensions.{dimension} table can only contain strings`
				)
			end
		end
	end

	local success: boolean, secretKey: string? = pcall(function()
		if options.secretKey then
			return options.secretKey
		end

		-- Check for secret key in the experience settings
		local secretSuccess, secret = pcall(function()
			return HttpService:GetSecret(options.secret)
		end)

		if secretSuccess and string.len(secret) == 0 then
			secret = nil
		end

		if not secretSuccess or not secret then
			-- If the secret is not found, try falling back to "secretKey"
			secret = options.secretKey
		end

		return secret
	end)

	if not success or not secretKey then
		if options.secret then
			error(
				`Analytics.start - Failed to get secret "{options.secret}" from Roblox. Check your domain list on the secrets page.`
			)
		end

		return
	end

	configuration = {
		currencies = options.currencies or { "Coins" },
		build = options.build or "dev",
		gameKey = options.gameKey,
		secretKey = secretKey,
		customDimensions = options.customDimensions or {},
		logErrors = options.logErrors or false,
	}

	-- Start analytics services
	startGameAnalytics()

	-- Set up listeners
	handleListeners()

	analyticsStarted = true
end

--[=[
	Used to track player events (example: player killed an enemy, player completed a mission, etc.)

	Examples
	```lua
	Analytics.logPlayerEvent({
		player = Player,
		event = "Player:KilledEnemy",
		value = 1 -- Killed 1 enemy
	})
	Analytics.logPlayerEvent({
		player = Player,
		event = "Player:CompletedMission",
		value = 1 -- Completed 1 mission
	})
	Analytics.logPlayerEvent({
		player = Player,
		event = "Player:Death",
		value = 1
	})
	```

	@server
	@param data BaseEvent
	//@external Promise https://eryn.io/roblox-lua-promise/api/Promise
	@return Promise
]=]
function Analytics.logPlayerEvent(data: BaseEvent): Promise<nil, string>
	return Promise.new(function(resolve, reject)
		if isClient then
			-- Forward to the server for processing
			remote:FireServer("LOG_PLAYER_EVENT", data)
			return resolve()
		end

		data.value = data.value or 1

		local validated: boolean, reason: string? = Validate.playerEvent(data):await()

		if not validated then
			return reject(reason)
		elseif not data.player then
			return reject("player is required")
		end

		local event: string = formatEventString(data.event)

		AnalyticsService:LogCustomEvent(
			data.player,
			event,
			data.value,
			getCustomFields(data.event)
		)

		gaWrapper("addDesignEvent", data.player.UserId, {
			eventId = data.event,
			value = data.value,
		})

		return resolve()
	end):catch(catch)
end

--[=[
	```lua
	Analytics.logMarketplacePurchase({
		player = Player,
		itemType = "Product",
		id = 000000000, -- Asset Id
		cartType = "PromptPurchase",
		robuxPrice = 100
	})
	```

	@server
	@param data MarketplacePurchaseEvent
	//@external Promise https://eryn.io/roblox-lua-promise/api/Promise
	@return Promise
]=]
function Analytics.logMarketplacePurchase(
	data: MarketplacePurchaseEvent
): Promise<nil, string>
	return Promise.new(function(resolve, reject)
		if not analyticsStarted then
			return reject("Analytics must be configured with :Start()")
		elseif not data.player then
			return reject("player is required")
		elseif not data.itemType then
			return reject("itemType is required")
		elseif not data.id then
			return reject("id is required")
		elseif not data.cartType then
			return reject("cartType is required")
		end

		gaWrapper("addBusinessEvent", data.player.UserId, {
			itemType = data.itemType,
			itemId = typeof(data.id) == "number" and tostring(data.id) or data.id,
			amount = data.robuxPrice or 0,
			cartType = data.cartType,
		})

		return resolve()
	end):catch(catch)
end

--[=[


	```lua
	local TeleportService = game:GetService("TeleportService")

	local TELEPORT_PLACE_ID = 000000000 -- Replace with your place ID

	local teleportData = {
		map = "Map 1",
		mission = "Mission Name",
		-- Add any other data you want to send
	}

	Analytics.addTeleportData({
		players = Players:GetPlayers(),
		teleportData = missionData,
	})

	local teleportOptions = Instance.new("TeleportOptions")
	teleportOptions:SetTeleportData(teleportData)

	TeleportService:TeleportAsync(TELEPORT_PLACE_ID, {player}, teleportOptions)
	```

	@server
	@param data TeleportEvent
	//@external Promise https://eryn.io/roblox-lua-promise/api/Promise
	@return { [string]: any } -- The modified teleportData table
]=]
function Analytics.addTeleportData(
	data: TeleportEvent
): Promise<{ [string]: any }, string>
	local playerIds = {}

	for _, player in data.players do
		table.insert(playerIds, player.UserId)
	end

	if not analyticsStarted then
		return Promise.reject("Analytics must be configured with :Start()")
	elseif not data.players then
		return Promise.reject("data.players must be defined")
	elseif not data.teleportData then
		return Promise.reject("data.teleportData is required")
	elseif typeof(data.teleportData) ~= "table" then
		return Promise.reject("data.teleportData must be a table")
	end

	-- Run the wrapper asynchronously. Since this doesn't yield
	local success, newTeleportData =
		gaWrapper("addGameAnalyticsTeleportData", playerIds, data.teleportData):await()

	return Promise.resolve(if success then newTeleportData else data.teleportData)
end

--[=[
	Shortcut function for logResourceEvent
	Used to log in-game currency purchases

	Example Use:
	```lua
	Analytics.logPurchase({
		player = Player,
		eventType = "Shop",
		currency = "Coins",
		itemId = "Red Paintball Gun"
	})
	```

	@server
	@param data PurchaseEvent
	//@external Promise https://eryn.io/roblox-lua-promise/api/Promise
	@return Promise
]=]
function Analytics.logPurchase(data: PurchaseEvent): Promise<nil, string>
	return Promise.new(function(resolve, reject)
		if not analyticsStarted then
			return reject("Analytics must be configured with :Start()")
		elseif not data.player then
			return reject("player is required")
		elseif typeof(data.eventType) ~= "string" then
			return reject("eventType must be a string")
		elseif not data.itemId then
			return reject("itemId is required")
		elseif not data.currency then
			return reject("currency is required")
		elseif not table.find(configuration.currencies, data.currency) then
			return reject("currency type is invalid")
		elseif data.amount ~= nil and typeof(data.amount) ~= "number" then
			return reject("amount is required")
		elseif
			data.flowType ~= nil
			and not GameAnalytics.EGAResourceFlowType[data.flowType]
		then
			return reject("flow type is invalid")
		end

		if not table.find(resourceEventTypes, data.eventType) then
			resourceEventTypes[#resourceEventTypes + 1] = data.eventType
			GameAnalytics.Events:setAvailableResourceItemTypes(resourceEventTypes) -- Update the SDK
		end

		Analytics.logResourceEvent({
			player = data.player,
			amount = data.amount or 1,
			currency = data.currency,
			flowType = data.flowType or "Sink",
			eventType = data.eventType,
			itemId = data.itemId,
		})

		return resolve()
	end):catch(catch)
end

--[=[
	Used to log in-game currency changes (example: player spent coins in a shop,
	player purchased coins, player won coins in a mission)

	Example Use:
	```lua
	-- Player purchased 100 coins with Robux
	Analytics.logResourceEvent({
		player = Player,
		eventType = "Purchase",
		currency = "Coins",
		itemId = "100 Coins",
		flowType = "Source",
		amount = 100
	})
	```

	@server
	@param data ResourceEvent
	//@external Promise https://eryn.io/roblox-lua-promise/api/Promise
	@return Promise
]=]
function Analytics.logResourceEvent(data: ResourceEvent): Promise<nil, string>
	return Promise.new(function(resolve, reject)
		if not analyticsStarted then
			return reject("Analytics must be configured with :Start()")
		elseif not data.player then
			return reject("player is required")
		elseif data.eventType and typeof(data.eventType) ~= "string" then
			return reject("eventType must be a string")
		elseif not data.itemId then
			return reject("itemId is required")
		elseif not data.currency then
			return reject("currency is required")
		elseif not table.find(configuration.currencies, data.currency) then
			return reject("currency type is invalid")
		elseif typeof(data.amount) ~= "number" then
			return reject("amount is required")
		end

		if data.eventType and not table.find(resourceEventTypes, data.eventType) then
			resourceEventTypes[#resourceEventTypes + 1] = data.eventType
			GameAnalytics.Events:setAvailableResourceItemTypes(resourceEventTypes) -- Update the SDK
		end

		AnalyticsService:LogEconomyEvent(
			data.player,
			data.flowType == "Source" and Enum.AnalyticsEconomyFlowType.Source
				or Enum.AnalyticsEconomyFlowType.Sink,
			data.currency,
			data.amount,
			data.endingBalance or 0,
			data.eventType or DEFAULT_TRANSACTION_TYPE,
			formatItemId(data.itemId),
			data.fields and stringTableToRobloxCustomFields(data.fields) or {}
		)

		gaWrapper("addResourceEvent", data.player.UserId, {
			-- FlowType is Sink by default
			flowType = GameAnalytics.EGAResourceFlowType[data.flowType]
				or GameAnalytics.EGAResourceFlowType.Sink,
			currency = data.currency,
			amount = data.amount,
			itemType = data.eventType or DEFAULT_TRANSACTION_TYPE,
			itemId = formatItemId(data.itemId),
		})

		return resolve()
	end):catch(catch)
end

--[=[
	Used to log errors

	Example Use:
	```lua
	local missionName: string = "Invalid Mission Name"

	Analytics.logError({
		player = Player,
		message = "Player tried to join a mission that doesn't exist named " .. missionName,
		severity = "Error"
	})
	```

	@server
	@param data ErrorEvent
	//@external Promise https://eryn.io/roblox-lua-promise/api/Promise
	@return Promise
]=]
function Analytics.logError(data: ErrorEvent): Promise<nil, string>
	return Promise.new(function(resolve, reject)
		if not analyticsStarted then
			return reject("Analytics must be configured with :Start()")
		elseif not data.player then
			return reject("player is required")
		elseif not data.message then
			return reject("message is required")
		elseif
			data.severity ~= nil and not GameAnalytics.EGAErrorSeverity[data.severity]
		then
			return reject("severity is invalid")
		end

		local errorSeverity: string = data.severity
			or GameAnalytics.EGAErrorSeverity.error

		gaWrapper("addErrorEvent", data.player.UserId, {
			message = data.message,
			severity = GameAnalytics.EGAErrorSeverity[errorSeverity],
		})

		return resolve()
	end):catch(catch)
end

--[=[
	**If logging FTUE/Onboarding progression, use "Onboarding" as the `eventId`!**

	Used to track player progression flows (example: player scores in a mission or level).

	Example:
	```lua
	Analytics.logPlayerProgression({
		player = Player,
		status = "Start",
		eventId = "Obby Course",
		step = 1, -- Checkpoint1
		stepName = "Checkpoint",
	})
	Analytics.logPlayerProgression({
		player = Player,
		status = "Complete",
		eventId = "Obby Course",
		step = 1, -- Checkpoint1
		stepName = "Checkpoint",
	})
	```

	@server
	@param data ProgressionEvent
	//@external Promise https://eryn.io/roblox-lua-promise/api/Promise
	@return Promise
]=]
function Analytics.logPlayerProgression(data: ProgressionEvent): Promise<nil, string>
	return Promise.new(function(resolve, reject)
		if not analyticsStarted then
			return reject("Analytics must be configured with Analytics.start()")
		elseif not data.player then
			return reject("player is required")
		elseif not data.status then
			return reject("status is required")
		elseif not data.eventId then
			return reject("eventId is required")
		elseif data.step ~= nil and typeof(data.step) ~= "number" then
			return reject("step must be a number")
		elseif data.stepName ~= nil and typeof(data.stepName) ~= "string" then
			return reject("stepName must be a string")
		elseif data.value ~= nil and typeof(data.value) ~= "number" then
			return reject("value must be a number")
		end

		if data.eventId == "Onboarding" then
			AnalyticsService:LogOnboardingFunnelStepEvent(
				data.player,
				data.step,
				data.stepName,
				stringTableToRobloxCustomFields(data.fields)
			)
		else
			AnalyticsService:LogProgressionEvent(
				data.player,
				data.eventId,
				data.status,
				data.step,
				data.stepName,
				stringTableToRobloxCustomFields(data.fields)
			)
		end

		gaWrapper("addProgressionEvent", data.player.UserId, {
			progressionStatus = GameAnalytics.EGAProgressionStatus[data.status]
				or "Start",
			progression01 = data.eventId,
			progression02 = `{data.stepName}_{data.step}`,
			score = data.value or 0,
		})

		return resolve()
	end):catch(catch)
end

--[=[
	Used to add a delayed event that fires when the player leaves

	Example usage:
	```lua
	Analytics.addDelayedEvent({
		player = Player,
		event = "Player:ClaimedReward"
	})
	```

	@param data BaseEvent
	//@external Promise https://eryn.io/roblox-lua-promise/api/Promise
	@return Promise
]=]
function Analytics.addDelayedEvent(data: BaseEvent): Promise<nil, string>
	return Promise.new(function(resolve, reject)
		if isClient then
			-- Forward to the server for processing
			remote:FireServer("ADD_DELAYED_EVENT", data)
			return resolve()
		end

		data.value = data.value or 1

		local validated: boolean, reason: string? = Validate.playerEvent(data):await()

		if not validated then
			return reject(reason)
		elseif not data.player then
			return reject("player is required")
		end

		if not events[data.player] then
			events[data.player] = {}
		end

		events[data.player][#events[data.player] + 1] = {
			event = formatEventString(data.event),
			value = data.value,
		}

		return resolve()
	end):catch(catch)
end

--[=[
	Used to add a value to a tracked event

	Example Use:
	```lua
	Analytics.addTrackedValue({
		player = Player,
		event = "Player:Kills",
		value = 2 -- Optional, defaults to 1
	})
	```

	Example client use:
	```lua
	Analytics.addTrackedValue:Fire({
		event = "UIEvent:OpenedShop"
	})
	```

	@param data BaseEvent
	@return Promise
]=]
function Analytics.addTrackedValue(data: BaseEvent): Promise<nil, string>
	return Promise.new(function(resolve, reject)
		if isClient then
			-- Forward to the server for processing
			remote:FireServer("ADD_TRACKED_VALUE", data)
			return resolve()
		end

		data.value = data.value or 1

		local validated: boolean, reason: string? = Validate.playerEvent(data):await()

		if not validated then
			return reject(reason)
		end

		if not trackedEvents[data.player] then
			trackedEvents[data.player] = {}
		end

		if not trackedEvents[data.player][data.event] then
			trackedEvents[data.player][data.event] = 0
		end

		trackedEvents[data.player][data.event] += data.value or 1

		return resolve()
	end):catch(catch)
end

-- Fake data used to communicate with GameAnalytics APIs
local function getServerPsuedoPlayer(): ServerPsuedoPlayer
	return {
		id = "DummyId",
		PlayerData = {
			OS = "uwp_desktop 0.0.0",
			Platform = "uwp_desktop",
			sessionId = HttpService:GenerateGUID(false):lower(),
			Sessions = 1,
			CustomUserId = "Server",
		},
	}
end

--[=[
	Get the value of a remote configuration or A/B test given context (player.UserId)

	Example Use:
	```lua
	local success: boolean, remoteValue: string? = Analytics.getRemoteConfig({
		player = player,
		name = "Test",
		defaultValue = "Default"
	}):await()
	```

	```lua
	Analytics.getRemoteConfig({
		player = player,
		name = "Test",
		defaultValue = "Default"
	})
		:andThen(
		function(remoteValue: string)
			print(remoteValue)
		end)
	```

	@within Analytics
	@param remoteConfig RemoteConfig -- The name, default value, and context of the remote configuration
	//@external Promise https://eryn.io/roblox-lua-promise/api/Promise
	@return Promise
]=]
function Analytics.getRemoteConfig(remoteConfig: RemoteConfig): Promise<string, string>
	return Promise.new(function(resolve, reject)
		if not remoteConfig then
			return reject("Analytics.getRemoteConfig - remoteConfig is required")
		elseif not remoteConfig.name then
			return reject("Analytics.getRemoteConfig - remoteConfig.name is required")
		elseif not remoteConfig.defaultValue then
			return reject(
				"Analytics.getRemoteConfig - remoteConfig.defaultValue is required"
			)
		end

		if not analyticsStarted then
			return resolve(remoteConfig.defaultValue)
		end

		local player: Player? = remoteConfig.player
		local context: ServerPsuedoPlayer = getServerPsuedoPlayer()
		local server = if player == nil
			then GameAnalytics.HttpApi:initRequest(
				configuration.gameKey,
				configuration.secretKey,
				configuration.build,
				context.PlayerData :: any,
				""
			)
			else nil

		if server and server.statusCode >= 9 and server.body then
			for _, config in (server.body.configs or {}) do
				if config.key == remoteConfig.name then
					return resolve(config.value)
				end
			end
		end

		if player and not GameAnalytics:isRemoteConfigsReady(player.UserId) then
			return resolve(remoteConfig.defaultValue)
		end

		return resolve(
			player
					and GameAnalytics:getRemoteConfigsValueAsString(player.UserId, {
						key = remoteConfig.name,
						defaultValue = remoteConfig.defaultValue,
					})
				or remoteConfig.defaultValue
		)
	end):catch(catch)
end

-- GameAnalytics method aliases for custom dimensions
local dimensionSetter: { [AnalyticsTypes.GADimension]: string } = {
	dimension01 = "setCustomDimension01",
	dimension02 = "setCustomDimension02",
	dimension03 = "setCustomDimension03",
}

--[=[
	Used to set a custom dimension for a player

	Example Use:
	```lua
	Analytics.setCustomDimension({
		player = Player,
		dimension = "dimension01",
		value = "value"
	})
	```

	To remove a custom dimension from a player, set the value to "".

	For more information about dimensions, refer to [GameAnalytics docs](https://docs.gameanalytics.com/integrations/sdk/roblox/sdk-features?_highlight=dimension#custom-dimensions) on dimensions.

	@param data DimensionData
	//@external Promise https://eryn.io/roblox-lua-promise/api/Promise
	@return Promise
]=]
function Analytics.setCustomDimension(data: DimensionData): Promise<nil, string>
	return Promise.new(function(resolve, reject)
		if isClient then
			-- Forward to the server for processing
			remote:FireServer("SET_CUSTOM_DIMENSION", data)

			return resolve()
		end

		local validated: boolean, reason: string? = Validate.dimensionData(data):await()

		if not validated then
			return reject(reason)
		elseif not data.player then
			return reject("player is required")
		end

		local dimensions = configuration.customDimensions
			and configuration.customDimensions[data.event]

		if not configuration.customDimensions then
			return reject(
				"Analytics.setCustomDimension - customDimensions was not defined during Analytics.start()"
			)
		elseif not dimensions then
			return reject(
				"Analytics.setCustomDimension - dimension is invalid, please define it in customDimensions during Analytics.start()"
			)
		elseif dimensions and not table.find(dimensions, data.value) then
			return reject(
				"Analytics.setCustomDimension - dimension value is invalid, please define it as a value in customDimensions during Analytics.start()"
			)
		end

		local setter: string? = dimensionSetter[data.event]

		if not setter then
			return reject("Analytics.setCustomDimension - dimension is invalid")
		end

		gaWrapper(setter, data.player.UserId, data.value)

		return resolve()
	end):catch(catch)
end

--[=[
	Logs an event to the server

	@client
	@param event string
	@param value number? -- Defaults to 1
]=]
function Analytics.logEvent(event: string, value: number?)
	assert(typeof(event) == "string", "event must be a string")
	assert(value == nil or typeof(value) == "number", "value must be a number or nil")

	remote:FireServer("LOG_PLAYER_EVENT", {
		event = formatEventString(event),
		value = value or 1,
	})
end

--[=[
	Logs a progression event to the server

	@client
	@param data ProgressionEvent
]=]
function Analytics.logProgression(data: ProgressionEvent)
	remote:FireServer("LOG_PROGRESSION_EVENT", data)
end

return Analytics
