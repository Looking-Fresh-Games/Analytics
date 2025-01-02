--[=[
	@interface BaseEvent
	.event string
	.value number?
	.player Player? -- Player who triggered the event (set on the server)
	.fields { [string]: any }? -- Additional fields to be sent with the event
	@within Analytics
]=]
export type BaseEvent = {
	event: string,
	value: number?,
	player: Player?,
	fields: { [string]: any }?,
}

--[=[
	Allowed dimensions for GameAnalytics

	@type GADimension "dimension01" | "dimension02" | "dimension03"
	@within Analytics
]=]
export type GADimension = "dimension01" | "dimension02" | "dimension03"

--[=[
	@type FlowType "Sink" | "Source"
	@within Analytics
]=]
export type FlowType = "Sink" | "Source"

--[=[
	The type of transaction that occurred. While you're free to use any transaction type, it's recommended to use the provided types.

	Up to 20 unique transaction types can be used per experience.

	Refer to the creator hub documentation for more information:
	https://create.roblox.com/docs/reference/engine/classes/AnalyticsService#LogEconomyEvent
	https://create.roblox.com/docs/reference/engine/enums/AnalyticsEconomyTransactionType

	@type TransactionType "IAP" | "Shop" | "Gameplay" | "ContextualPurchase" | "TimedReward" | "Onboarding" | string
	@within Analytics
]=]
export type TransactionType =
	"IAP"
	| "Shop"
	| "Gameplay"
	| "ContextualPurchase"
	| "TimedReward"
	| "Onboarding"
	| string

--[=[
	Progression statuses for progression events

	@type ProgressionStatus "Start" | "Fail" | "Complete"
	@within Analytics
]=]
export type ProgressionStatus = "Start" | "Fail" | "Complete"

--[=[
	@interface DimensionData
	@within Analytics
	.dimension GADimension
	.value string
	.player Player -- Player who triggered the event
]=]
export type DimensionData = {
	event: GADimension,
	value: string,
	player: Player,
}

--[=[
	@type CustomDimensions { [string]: { string } }
	@within Analytics
]=]
export type CustomDimensions = {
	[string]: { string },
}

--[=[
	@interface MarketplacePurchaseEvent
	@within Analytics
	.player Player
	.itemType string
	.id number | string
	.robuxPrice number?
	.cartType string
]=]
export type MarketplacePurchaseEvent = {
	player: Player,
	itemType: string,
	id: number | string,
	robuxPrice: number?,
	cartType: string,
}

--[=[
	Currency is the in-game currency type used, it must be defined in `Analytics:Start()`

	@interface PurchaseEvent
	@within Analytics
	.player Player
	.eventType string -- 1 by default
	.itemId string
	.currency string -- In-game currency type used
	.amount number? -- Amount of currency spent
	.endingBalance number? -- Ending balance of currency
	.flowType FlowType? -- Allowed flow types: "Sink", "Source" (defaults to "Sink")
	.fields { string }? -- Additional fields to be sent with the event
]=]
export type PurchaseEvent = {
	player: Player,
	eventType: string,
	itemId: string,
	currency: string,
	amount: number?,
	endingBalance: number?,
	flowType: FlowType?,
	fields: { string }?,
}

--[=[
	Notes:
	Currency: The in-game currency type used, it must be defined in `Analytics:Start()`

	EventType: For sink events it can describe an item category you are buying (Weapons) or a place (Gameplay) the currency was consumed.
	For source events it can describe how the currency was gained.
	For example “IAP” (for in-app purchase) or from using another currency (Gems).

	FlowType: The flow type of the event. Allowed flow types: "Sink", "Source" (defaults to "Sink")

	Fields: Additional fields to be sent with the event

	@interface ResourceEvent
	@within Analytics
	.player Player
	.eventType string
	.itemId string -- unique id of item (example: "100 Coins", "Coin Pack", "Red Loot Box", "Extra Life")
	.currency string
	.amount number
	.endingBalance number?
	.flowType FlowType? -- Defaults to "Sink"
	.fields { string }?
]=]
export type ResourceEvent = {
	player: Player,
	eventType: string,
	itemId: string,
	currency: string,
	amount: number,
	endingBalance: number?,
	flowType: FlowType?,
	fields: { string }?,
}

--[=[
	@interface ErrorEvent
	@within Analytics
	.message string
	.severity string? -- Allowed severities: "debug", "info", "warning", "error", "critical" (defaults to "error")
	.player Player? -- Player who triggered the event (set on the server)
]=]
export type ErrorEvent = {
	message: string,
	severity: string?,
	player: Player,
}

--[=[
	@interface ProgressionEvent
	@within Analytics
	.player Player
	.status string -- Status in the progression step
	.eventId string -- Unique identifier for the event
	.step number -- Step number in the progression flow
	.stepName string -- Name of the step
	.value number? -- Optional value/score for the progression step
	.fields { string }? -- Additional fields to be sent with the event
]=]
export type ProgressionEvent = {
	player: Player,
	status: "Start" | "Fail" | "Complete",
	eventId: string,
	step: number,
	stepName: string,
	value: number?,
	fields: { string }?,
}

--[=[
	@interface DimensionEvent
	@within Analytics
	.dimension GADimension
	.value string
]=]
export type DimensionEvent = BaseEvent & {
	dimension: GADimension,
	value: string,
}

--[=[
	@interface RemoteConfig
	@within Analytics
	.player Player?
	.name string
	.defaultValue string
	.value string?
]=]
export type RemoteConfig = {
	player: Player?,
	name: string,
	defaultValue: string,
	value: string?,
}

--[=[
	@interface PsuedoPlayerData
	@within Analytics
	.OS string -- "uwp_desktop 0.0.0"
	.Platform string
	.sessionId string -- lowercase GenerateGUID(false)
	.Sessions number -- 1
	.CustomUserId string -- "Server
]=]
export type PsuedoPlayerData = {
	OS: "uwp_desktop 0.0.0",
	Platform: "uwp_desktop",
	sessionId: string,
	Sessions: number,
	CustomUserId: "Server",
}

--[=[
	@interface ServerPsuedoPlayer
	@within Analytics
	.id string -- "DummyId"
	.PlayerData PsuedoPlayerData
]=]
export type ServerPsuedoPlayer = {
	id: "DummyId",
	PlayerData: PsuedoPlayerData,
}

--[=[
	@interface AnalyticsOptions
	@within Analytics
	.currencies { string? }? -- List of all in-game currencies (defaults to { "Coins" })
	.build string? -- Game version
	.gameKey string -- GameAnalytics game key
	.secretKey string -- GameAnalytics secret key
	.secret string? -- Roblox secret name
	.customDimensions CustomDimensions? -- Custom dimensions to be used in GameAnalytics (refer to [GameAnalytics docs](https://docs.gameanalytics.com/advanced-tracking/custom-dimensions) about dimensions)
	.logErrors boolean? -- Whether or not to log errors (defaults to false)
]=]
export type AnalyticsOptions = {
	currencies: { string }?,
	build: string?,
	gameKey: string,
	secretKey: string,
	secret: string?,
	customDimensions: CustomDimensions?,
	logErrors: boolean?,
}

-- The Promise library isn't typed so we have to create our own type
-- //@external Promise https://eryn.io/roblox-lua-promise/api/Promise
export type Promise = {
	new: (callback: (resolve: () -> (), reject: () -> ()) -> ()) -> Promise,
	resolve: (value: any) -> Promise,
	reject: (value: any) -> Promise,
	andThen: (Promise, callback: (any) -> ()) -> Promise,
	catch: (Promise, callback: (any) -> ()) -> Promise,
	finally: (Promise, callback: (any) -> ()) -> Promise,
	cancel: (Promise) -> (),
	await: (Promise) -> (any, any),
	expect: (Promise) -> (any, any),
	getStatus: (Promise) -> string,
	Status: {
		Started: "Started", -- The Promise is executing, and not settled yet.
		Resolved: "Resolved", -- The Promise finished successfully.
		Rejected: "Rejected", -- The Promise was rejected.
		Cancelled: "Cancelled", -- The Promise was cancelled before it finished.
	},
}

return nil
