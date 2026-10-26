# express-event-processor

An EXPRESS workflow in JSONata, started by an EventBridge rule for every
object created in a bucket (the bucket must send events to EventBridge).
Express keeps no execution history, so logging at ERROR is the only record
of a failure; events EventBridge cannot deliver after its retries go to the
dead-letter queue. At 3 million executions a month this costs about $4
(see [COSTS.md](../../COSTS.md)); the same on STANDARD would be about $225.
