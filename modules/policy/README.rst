.. _mod-policy:

Query policies
--------------

This module can block, rewrite, or alter inbound queries based on user-defined policies.
By default, if no rule applies to a query, rules for special-use domain names are applied, as required by :rfc:`6761`.

You can however extend it e.g. to deflect `Slow drip DNS attacks <https://secure64.com/water-torture-slow-drip-dns-ddos-attack>`_ or gray-list resolution of misbehaving zones.

There are several policy filters available in the ``policy.`` table:

* ``all(action)``
  - always applies the action
* ``pattern(action, pattern)``
  - applies the action if QNAME matches a `regular expression <http://lua-users.org/wiki/PatternsTutorial>`_
* ``suffix(action, table)``
  - applies the action if QNAME suffix matches one of suffixes in the table (useful for "is domain in zone" rules),
  uses `Aho-Corasick`_ string matching algorithm `from CloudFlare <https://github.com/cloudflare/lua-aho-corasick>`_ (BSD 3-clause)
* :any:`policy.suffix_common`
* ``rpz``
  - implements a subset of RPZ_ in zonefile format.  See below for details: :any:`policy.rpz`.
* custom filter function

There are several actions available in the ``policy.`` table:

* ``PASS`` - let the query pass through; it's useful to make exceptions before wider rules
* ``DENY`` - reply NXDOMAIN authoritatively
* ``DROP`` - terminate query resolution and return SERVFAIL to the requestor
* ``TC`` - set TC=1 if the request came through UDP, forcing client to retry with TCP
* ``FORWARD(ip)`` - solve a query via forwarding to an IP while validating and caching locally;
  the parameter can be a single IP (string) or a lua list of up to four IPs.
* ``STUB(ip)`` - similar to ``FORWARD(ip)`` but *without* attempting DNSSEC validation.
  Each request may be either answered from cache or simply sent to one of the IPs with proxying back the answer.
* ``MIRROR(ip)`` - mirror query to given IP and continue solving it (useful for partial snooping); it's a chain action
* ``REROUTE({{subnet,target}, ...})`` - reroute addresses in response matching given subnet to given target, e.g. ``{'192.0.2.0/24', '127.0.0.0'}`` will rewrite '192.0.2.55' to '127.0.0.55', see :ref:`renumber module <mod-renumber>` for more information.
* ``QTRACE`` - pretty-print DNS response packets into the log for the query and its sub-queries.  It's useful for debugging weird DNS servers.  It's a chain action.
* ``FLAGS(set, clear)`` - set and/or clear some flags for the query.  There can be multiple flags to set/clear.  You can just pass a single flag name (string) or a set of names.  It's a chain action.

Most actions stop the policy matching on the query, but "chain actions" allow to keep trying to match other rules, until a non-chain action is triggered.

.. warning:: The policy module currently only looks at whole DNS requests.  The rules won't be re-applied e.g. when following CNAMEs.

.. note:: The module (and ``kres``) expects domain names in wire format, not textual representation. So each label in name is prefixed with its length, e.g. "example.com" equals to ``"\7example\3com"``. You can use convenience function ``todname('example.com')`` for automatic conversion.

Examples
^^^^^^^^

.. code-block:: lua

	-- Load default policies
	modules = { 'policy' }
	-- Whitelist 'www[0-9].badboy.cz'
	policy.add(policy.pattern(policy.PASS, '\4www[0-9]\6badboy\2cz'))
	-- Block all names below badboy.cz
	policy.add(policy.suffix(policy.DENY, {todname('badboy.cz.')}))
	-- Custom rule
	policy.add(function (req, query)
		if query:qname():find('%d.%d.%d.224\7in-addr\4arpa') then
			return policy.DENY
		end
	end)
	-- Disallow ANY queries
	policy.add(function (req, query)
		if query.stype == kres.type.ANY then
			return policy.DROP
		end
	end)
	-- Enforce local RPZ
	policy.add(policy.rpz(policy.DENY, 'blacklist.rpz'))
	-- Forward all queries below 'company.se' to given resolver
	policy.add(policy.suffix(policy.FORWARD('192.168.1.1'), {todname('company.se')}))
	-- Forward all queries matching pattern
	policy.add(policy.pattern(policy.FORWARD('2001:DB8::1'), '\4bad[0-9]\2cz'))
	-- Forward all queries (to public resolvers https://www.nic.cz/odvr)
	policy.add(policy.all(policy.FORWARD({'2001:678:1::206', '193.29.206.206'})))
	-- Print all responses with matching suffix
	policy.add(policy.suffix(policy.QTRACE, {todname('rhybar.cz.')}))
	-- Print all responses
	policy.add(policy.all(policy.QTRACE))
	-- Mirror all queries and retrieve information
	local rule = policy.add(policy.all(policy.MIRROR('127.0.0.2')))
	-- Print information about the rule
	print(string.format('id: %d, matched queries: %d', rule.id, rule.count)
	-- Reroute all addresses found in answer from 192.0.2.0/24 to 127.0.0.x
	-- this policy is enforced on answers, therefore 'postrule'
	local rule = policy.add(policy.REROUTE({'192.0.2.0/24', '127.0.0.0'}), true)
	-- Delete rule that we just created
	policy.del(rule.id)

Additional properties
^^^^^^^^^^^^^^^^^^^^^

Most properties (actions, filters) are described above.

.. function:: policy.add(rule, postrule)

  :param rule: added rule, i.e. ``policy.pattern(policy.DENY, '[0-9]+\2cz')``
  :param postrule: boolean, if true the rule will be evaluated on answer instead of query
  :return: rule description

  Add a new policy rule that is executed either or queries or answers, depending on the ``postrule`` parameter. You can then use the returned rule description to get information and unique identifier for the rule, as well as match count.

.. function:: policy.del(id)

  :param id: identifier of a given rule
  :return: boolean

  Remove a rule from policy list.

.. function:: policy.suffix_common(action, suffix_table[, common_suffix])

  :param action: action if the pattern matches QNAME
  :param suffix_table: table of valid suffixes
  :param common_suffix: common suffix of entries in suffix_table

  Like suffix match, but you can also provide a common suffix of all matches for faster processing (nil otherwise).
  This function is faster for small suffix tables (in the order of "hundreds").

.. function:: policy.rpz(action, path[, format])

  :param action: the default action for match in the zone (e.g. RH-value `.`)
  :param path: path to zone file | database

  Enforce RPZ_ rules. This can be used in conjunction with published blocklist feeds.
  The RPZ_ operation is well described in this `Jan-Piet Mens's post`_,
  or the `Pro DNS and BIND`_ book. Here's compatibility table:

  .. csv-table::
   :header: "Policy Action", "RH Value", "Support"

   "NXDOMAIN", "``.``", "**yes**"
   "NODATA", "``*.``", "*partial*, implemented as NXDOMAIN"
   "Unchanged", "``rpz-passthru.``", "**yes**"
   "Nothing", "``rpz-drop.``", "**yes**"
   "Truncated", "``rpz-tcp-only.``", "**yes**"
   "Modified", "anything", "no"

  .. csv-table::
   :header: "Policy Trigger", "Support"

   "QNAME", "**yes**"
   "CLIENT-IP", "*partial*, may be done with :ref:`views <mod-view>`"
   "IP", "no"
   "NSDNAME", "no"
   "NS-IP", "no"

.. function:: policy.todnames({name, ...})

   :param: names table of domain names in textual format

   Returns table of domain names in wire format converted from strings.

   .. code-block:: lua

      -- Convert single name
      assert(todname('example.com') == '\7example\3com\0')
      -- Convert table of names
      policy.todnames({'example.com', 'me.cz'})
      { '\7example\3com\0', '\2me\2cz\0' }

.. _`Aho-Corasick`: https://en.wikipedia.org/wiki/Aho%E2%80%93Corasick_string_matching_algorithm
.. _`@jgrahamc`: https://github.com/jgrahamc/aho-corasick-lua
.. _RPZ: https://dnsrpz.info/
.. _`Pro DNS and BIND`: http://www.zytrax.com/books/dns/ch7/rpz.html
.. _`Jan-Piet Mens's post`: http://jpmens.net/2011/04/26/how-to-configure-your-bind-resolvers-to-lie-using-response-policy-zones-rpz/
