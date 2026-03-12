// Example: Simple Authorizer
// Minimal authorizer that always approves.
module simple_auth;

import jam::types;
import jam::log;

fn void is_authorized(types::IsAuthorizedArgs* args) @export("is_authorized")
{
    log::info("auth", "Authorizer: approving request");
}
