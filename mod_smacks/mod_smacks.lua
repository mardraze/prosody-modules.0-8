local st = require "util.stanza";

local t_insert, t_remove = table.insert, table.remove;
local tonumber, tostring = tonumber, tostring;

local xmlns_sm = "urn:xmpp:sm:2";

local sm_attr = { xmlns = xmlns_sm };

module:add_event_hook("stream-features",
		function (session, features)
			features:tag("sm", sm_attr):tag("optional"):up():up();
		end);

module:hook("s2s-stream-features",
		function (data)
			data.features:tag("sm", sm_attr):tag("optional"):up():up();
		end);

module:hook_stanza(xmlns_sm, "enable",
		function (session, stanza)
			module:log("debug", "Enabling stream management");
			session.smacks = true;
			session.handled_stanza_count = 0;
			-- Overwrite process_stanza() and send()
			local queue, queue_length = {}, 0;
			session.outgoing_stanza_queue, session.outgoing_stanza_count = queue, queue_length;
			local _send = session.send;
			function session.send(stanza)
				local attr = stanza.attr;
				if attr and not attr.xmlns then -- Stanza in default stream namespace
					queue_length = queue_length + 1;
					session.outgoing_stanza_count = queue_length;
					queue[queue_length] = st.reply(stanza);
				end
				local ok, err = _send(stanza);
				if ok then
					return _send(st.stanza("r", { xmlns = xmlns_sm }));
				end
				return ok, err;
			end
			_send(st.stanza("enabled", sm_attr));
			return true;
		end);

module:hook_stanza(xmlns_sm, "r", function (origin, stanza)
	if not origin.smacks then
		module:log("debug", "Received ack request from non-smack-enabled session");
		return;
	end
	module:log("debug", "Received ack request, acking for %d", origin.handled_stanza_count);
	-- Reply with <a>
	origin.send(st.stanza("a", { xmlns = xmlns_sm, h = tostring(origin.handled_stanza_count) }));
	return true;
end);

module:hook_stanza(xmlns_sm, "a", function (origin, stanza)
	if not origin.smacks then return; end
	
	-- Remove handled stanzas from outgoing_stanza_queue
	local handled_stanza_count = tonumber(stanza.attr.h)+1;
	for i=1,handled_stanza_count do
		t_remove(origin.outgoing_stanza_queue, 1);
	end
	return true;
end);

--TODO: Optimise... incoming stanzas should be handled by a per-session
-- function that has a counter as an upvalue (no table indexing for increments,
-- and won't slow non-198 sessions). We can also then remove the .handled flag
-- on stanzas

function catch_all_incoming_stanzas(data)
	local origin, stanza = data.origin, data.stanza;
	if origin.smacks and not stanza.handled then
		stanza.handled = true;
		origin.handled_stanza_count = origin.handled_stanza_count + 1;
		module:log("debug", "Handled %d stanzas", origin.handled_stanza_count);
	end
end
module:hook("message/bare", catch_all_incoming_stanzas, 1000);
module:hook("message/full", catch_all_incoming_stanzas, 1000);
module:hook("message/host", catch_all_incoming_stanzas, 1000);

module:hook("presence/bare", catch_all_incoming_stanzas, 1000);
module:hook("presence/full", catch_all_incoming_stanzas, 1000);
module:hook("presence/host", catch_all_incoming_stanzas, 1000);

module:hook("iq/bare", catch_all_incoming_stanzas, 1000);
module:hook("iq/full", catch_all_incoming_stanzas, 1000);
module:hook("iq/host", catch_all_incoming_stanzas, 1000);

function handle_unacked_stanzas(session)
	local queue = session.outgoing_stanza_queue;
	local error_attr = { type = "cancel" };
	if #queue > 0 then
		for i=1,#queue do
			local reply = queue[i];
			if reply.attr.to ~= session.full_jid then
				reply.attr.type = "error";
				reply:tag("error", error_attr)
					:tag("recipient-unavailable", {xmlns = "urn:ietf:params:xml:ns:xmpp-stanzas"});
				core_process_stanza(session, queue[i]);
			end
			queue[i] = nil;
		end
	end
end

local _destroy_session = sessionmanager.destroy_session;
function sessionmanager.destroy_session(session, err)
	if session.smacks then
		local queue = session.outgoing_stanza_queue;
		if #queue > 0 then
			module:log("warn", "Destroying session with %d unacked stanzas:", #queue);
			for i=1,#queue do
				module:log("warn", "::%s", tostring(queue[i]));
			end
			handle_unacked_stanzas(session);
		end
	end
	return _destroy_session(session, err);
end