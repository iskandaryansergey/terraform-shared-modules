# order-workflow

A STANDARD workflow rendered from `order.asl.json.tftpl`: reserve stock and
take payment through Lambda (retried on throttling), release the stock if
payment fails, record the order in DynamoDB, notify through SNS.

`integrations` names each resource the definition calls. The table is named
by `TableName` in the definition, so only the Lambda functions and the topic
are compared by `every_arn_in_the_definition_is_granted`;
`tests/examples.tftest.hcl` plans this example and asserts nothing is
ungranted.

Before the first plan: the workspace's role needs
`states:ValidateStateMachineDefinition` (`output.deployer_requirements`).
