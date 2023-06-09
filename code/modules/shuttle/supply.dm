GLOBAL_LIST_INIT(blacklisted_cargo_types, typecacheof(list(
		/mob/living,
		/obj/structure/blob,
		/obj/effect/rune,
		/obj/item/disk/nuclear,
		/obj/machinery/nuclearbomb,
		/obj/item/beacon,
		/obj/narsie,
		/obj/tear_in_reality,
		/obj/machinery/teleport/station,
		/obj/machinery/teleport/hub,
		/obj/machinery/quantumpad,
		/obj/effect/mob_spawn,
		/obj/effect/hierophant,
		/obj/structure/receiving_pad,
		/obj/item/warp_cube,
		/obj/machinery/rnd/production, //print tracking beacons, send shuttle
		/obj/machinery/autolathe, //same
		/obj/projectile/beam/wormhole,
		/obj/effect/portal,
		/obj/item/shared_storage,
		/obj/structure/extraction_point,
		/obj/machinery/syndicatebomb,
		/obj/item/hilbertshotel,
		/obj/item/swapper,
		/obj/docking_port,
		/obj/machinery/launchpad,
		/obj/machinery/disposal,
		/obj/structure/disposalpipe,
		/obj/item/mail,
		/obj/machinery/camera,
		/obj/item/gps,
		/obj/structure/checkoutmachine,
		/obj/machinery/fax
	)))

/// How many goody orders we can fit in a lockbox before we upgrade to a crate
#define GOODY_FREE_SHIPPING_MAX 5
/// How much to charge oversized goody orders
#define CRATE_TAX 700

/obj/docking_port/mobile/supply
	name = "supply shuttle"
	shuttle_id = "cargo"
	callTime = 600

	dir = WEST
	port_direction = EAST
	movement_force = list("KNOCKDOWN" = 0, "THROW" = 0)

/obj/docking_port/mobile/supply/register()
	. = ..()
	SSshuttle.supply = src

/obj/docking_port/mobile/supply/canMove()
	if(is_station_level(z))
		return check_blacklist(shuttle_areas)
	return ..()

/obj/docking_port/mobile/supply/proc/check_blacklist(areaInstances)
	for(var/place in areaInstances)
		var/area/shuttle/shuttle_area = place
		for(var/turf/shuttle_turf in shuttle_area)
			for(var/atom/passenger in shuttle_turf.get_all_contents())
				if((is_type_in_typecache(passenger, GLOB.blacklisted_cargo_types) || HAS_TRAIT(passenger, TRAIT_BANNED_FROM_CARGO_SHUTTLE)) && !istype(passenger, /obj/docking_port))
					return FALSE
	return TRUE

/obj/docking_port/mobile/supply/request(obj/docking_port/stationary/S)
	if(mode != SHUTTLE_IDLE)
		return 2
	return ..()

/obj/docking_port/mobile/supply/initiate_docking()
	if(getDockedId() == "cargo_away") // Buy when we leave home.
		buy()
		create_mail()
	. = ..() // Fly/enter transit.
	if(. != DOCKING_SUCCESS)
		return
	if(getDockedId() == "cargo_away") // Sell when we get home
		sell()

/obj/docking_port/mobile/supply/proc/buy()
	SEND_SIGNAL(SSshuttle, COMSIG_SUPPLY_SHUTTLE_BUY)
	var/list/obj/miscboxes = list() //miscboxes are combo boxes that contain all goody orders grouped
	var/list/misc_order_num = list() //list of strings of order numbers, so that the manifest can show all orders in a box
	var/list/misc_contents = list() //list of lists of items that each box will contain
	var/list/misc_costs = list() //list of overall costs sustained by each buyer.

	var/list/empty_turfs = list()
	for(var/area/shuttle/shuttle_area as anything in shuttle_areas)
		for(var/turf/open/floor/shuttle_turf in shuttle_area)
			if(shuttle_turf.is_blocked_turf())
				continue
			empty_turfs += shuttle_turf

	//quickly and greedily handle chef's grocery runs first, there are a few reasons why this isn't attached to the rest of cargo...
	//but the biggest reason is that the chef requires produce to cook and do their job, and if they are using this system they
	//already got let down by the botanists. So to open a new chance for cargo to also screw them over any more than is necessary is bad.
	if(SSshuttle.chef_groceries.len)
		var/obj/structure/closet/crate/freezer/grocery_crate = new(pick_n_take(empty_turfs))
		grocery_crate.name = "kitchen produce freezer"
		investigate_log("Chef's [SSshuttle.chef_groceries.len] sized produce order arrived. Cost was deducted from orderer, not cargo.", INVESTIGATE_CARGO)
		for(var/datum/orderable_item/item as anything in SSshuttle.chef_groceries)//every order
			for(var/amt in 1 to SSshuttle.chef_groceries[item])//every order amount
				new item.item_path(grocery_crate)
		SSshuttle.chef_groceries.Cut() //This lets the console know it can order another round.

	if(!SSshuttle.shopping_list.len)
		return

	var/value = 0
	var/purchases = 0
	var/list/goodies_by_buyer = list() // if someone orders more than GOODY_FREE_SHIPPING_MAX goodies, we upcharge to a normal crate so they can't carry around 20 combat shotties
	var/list/forced_briefcases = list() //SKYRAT EDIT

	for(var/datum/supply_order/spawning_order in SSshuttle.shopping_list)
		if(!empty_turfs.len)
			break
		var/price = spawning_order.pack.get_cost()
		if(spawning_order.applied_coupon)
			price *= (1 - spawning_order.applied_coupon.discount_pct_off)

		var/datum/bank_account/paying_for_this

		//department orders EARN money for cargo, not the other way around
		//Skyrat Edit Add
		if(!spawning_order.department_destination && spawning_order.charge_on_purchase)
		//Skyrat Edit End
			if(spawning_order.paying_account) //Someone paid out of pocket
				paying_for_this = spawning_order.paying_account
				var/list/current_buyer_orders = goodies_by_buyer[spawning_order.paying_account] // so we can access the length a few lines down
				if(!spawning_order.pack.goody)
					price *= 1.1 //TODO make this customizable by the quartermaster

				// note this is before we increment, so this is the GOODY_FREE_SHIPPING_MAX + 1th goody to ship. also note we only increment off this step if they successfully pay the fee, so there's no way around it
				else if(LAZYLEN(current_buyer_orders) == GOODY_FREE_SHIPPING_MAX)
					price += CRATE_TAX
					paying_for_this.bank_card_talk("Goody order size exceeds free shipping limit: Assessing [CRATE_TAX] credit S&H fee.")
			else
				paying_for_this = SSeconomy.get_dep_account(ACCOUNT_CAR)
			if(paying_for_this)
				if(!paying_for_this.adjust_money(-price, "Cargo: [spawning_order.pack.name]"))
					if(spawning_order.paying_account)
						paying_for_this.bank_card_talk("Cargo order #[spawning_order.id] rejected due to lack of funds. Credits required: [price]")
					continue
		//Skyrat Edit Add
		if(spawning_order.paying_account && spawning_order.charge_on_purchase)
		//Skyrat Edit End
			paying_for_this = spawning_order.paying_account
			if(spawning_order.pack.goody)
				LAZYADD(goodies_by_buyer[spawning_order.paying_account], spawning_order)
			var/reciever_message = "Cargo order #[spawning_order.id] has shipped."
			if(spawning_order.charge_on_purchase)
				reciever_message += " [price] credits have been charged to your bank account"
			paying_for_this.bank_card_talk(reciever_message)
			SSeconomy.track_purchase(paying_for_this, price, spawning_order.pack.name)
			var/datum/bank_account/department/cargo = SSeconomy.get_dep_account(ACCOUNT_CAR)
			cargo.adjust_money(price - spawning_order.pack.get_cost()) //Cargo gets the handling fee
		value += spawning_order.pack.get_cost()
		SSshuttle.shopping_list -= spawning_order
		SSshuttle.order_history += spawning_order
		QDEL_NULL(spawning_order.applied_coupon)

		spawning_order.on_spawn() //SKYRAT EDIT
		if(!spawning_order.pack.goody && !(spawning_order?.paying_account in forced_briefcases)) //we handle goody crates below //SKYRAT EDIT
			spawning_order.generate(pick_n_take(empty_turfs))

		SSblackbox.record_feedback("nested tally", "cargo_imports", 1, list("[spawning_order.pack.get_cost()]", "[spawning_order.pack.name]"))

		var/from_whom = paying_for_this?.account_holder || "nobody (department order)"

		investigate_log("Order #[spawning_order.id] ([spawning_order.pack.name], placed by [key_name(spawning_order.orderer_ckey)]), paid by [from_whom] has shipped.", INVESTIGATE_CARGO)
		if(spawning_order.pack.dangerous)
			message_admins("\A [spawning_order.pack.name] ordered by [ADMIN_LOOKUPFLW(spawning_order.orderer_ckey)], paid by [from_whom] has shipped.")
		purchases++

	// we handle packing all the goodies last, since the type of crate we use depends on how many goodies they ordered. If it's more than GOODY_FREE_SHIPPING_MAX
	// then we send it in a crate (including the CRATE_TAX cost), otherwise send it in a free shipping case
	for(var/buyer_key in goodies_by_buyer)
		var/list/buying_account_orders = goodies_by_buyer[buyer_key]
		var/datum/bank_account/buying_account = buyer_key
		var/buyer = buying_account.account_holder

		if(buying_account_orders.len > GOODY_FREE_SHIPPING_MAX) // no free shipping, send a crate
			var/obj/structure/closet/crate/secure/owned/our_crate = new /obj/structure/closet/crate/secure/owned(pick_n_take(empty_turfs))
			our_crate.buyer_account = buying_account
			our_crate.name = "goody crate - purchased by [buyer]"
			miscboxes[buyer] = our_crate
		else //free shipping in a case
			miscboxes[buyer] = new /obj/item/storage/lockbox/order(pick_n_take(empty_turfs))
			var/obj/item/storage/lockbox/order/our_case = miscboxes[buyer]
			our_case.buyer_account = buying_account
			miscboxes[buyer].name = "goody case - purchased by [buyer]"
		misc_contents[buyer] = list()

		for(var/datum/supply_order/our_order as anything in buying_account_orders)
			for (var/item in our_order.pack.contains)
				misc_contents[buyer] += item
			misc_costs[buyer] += our_order.pack.cost
			misc_order_num[buyer] = "[misc_order_num[buyer]]#[our_order.id] "
	//SKYRAT EDIT START
	for(var/briefcase_order in forced_briefcases)
		var/list/buying_account_orders = forced_briefcases[briefcase_order]
		var/datum/bank_account/buying_account = briefcase_order
		var/buyer = buying_account.account_holder
		var/buying_acc_order_num = length(buying_account_orders)
		for(var/datum/supply_order/company_import/the_order in buying_account_orders)
			if(!the_order.item_amount || (the_order.item_amount == 1))
				continue
			buying_acc_order_num += the_order.item_amount - 1

		if(buying_acc_order_num > 2) // no free shipping, send a crate
			var/obj/structure/closet/crate/secure/owned/our_crate = new /obj/structure/closet/crate/secure/owned(pick_n_take(empty_turfs))
			our_crate.buyer_account = buying_account
			our_crate.name = "special import crate - purchased by [buyer]"
			miscboxes[buyer] = our_crate
		else //free shipping in a case
			miscboxes[buyer] = new /obj/item/storage/lockbox/order(pick_n_take(empty_turfs))
			var/obj/item/storage/lockbox/order/our_case = miscboxes[buyer]
			our_case.buyer_account = buying_account
			if(istype(our_case.buyer_account, /datum/bank_account/department))
				our_case.department_purchase = TRUE
				our_case.department_account = our_case.buyer_account
			miscboxes[buyer].name = "special import case - purchased by [buyer]"
		misc_contents[buyer] = list()

		for(var/datum/supply_order/order in buying_account_orders)
			for (var/item in order.pack.contains)
				misc_contents[buyer] += item
			misc_costs[buyer] += order.pack.cost
			misc_order_num[buyer] = "[misc_order_num[buyer]]#[order.id]  "
	//SKYRAT EDIT END

	for(var/miscbox in miscboxes)
		var/datum/supply_order/order = new/datum/supply_order()
		order.id = misc_order_num[miscbox]
		order.generateCombo(miscboxes[miscbox], miscbox, misc_contents[miscbox], misc_costs[miscbox])
		qdel(order)

	SSeconomy.import_total += value
	var/datum/bank_account/cargo_budget = SSeconomy.get_dep_account(ACCOUNT_CAR)
	investigate_log("[purchases] orders in this shipment, worth [value] credits. [cargo_budget.account_balance] credits left.", INVESTIGATE_CARGO)

/// Deletes and sells the items on the shuttle
/obj/docking_port/mobile/supply/proc/sell()
	var/datum/bank_account/cargo_budget = SSeconomy.get_dep_account(ACCOUNT_CAR)
	var/presale_points = cargo_budget.account_balance

	if(!GLOB.exports_list.len) // No exports list? Generate it!
		setupExports()

	var/msg = ""

	var/datum/export_report/report = new

	for(var/area/shuttle/shuttle_area as anything in shuttle_areas)
		for(var/atom/movable/exporting_atom in shuttle_area)
			if(iscameramob(exporting_atom))
				continue
			if(exporting_atom.anchored)
				continue
			export_item_and_contents(exporting_atom, apply_elastic = TRUE, dry_run = FALSE, external_report = report)

	if(report.exported_atoms)
		report.exported_atoms += "." //ugh

	for(var/datum/export/exported_datum in report.total_amount)
		var/export_text = exported_datum.total_printout(report)
		if(!export_text)
			continue

		msg += export_text + "\n"
		cargo_budget.adjust_money(report.total_value[exported_datum])

	SSeconomy.export_total += (cargo_budget.account_balance - presale_points)
	SSshuttle.centcom_message = msg
	investigate_log("contents sold for [cargo_budget.account_balance - presale_points] credits. Contents: [report.exported_atoms ? report.exported_atoms.Join(",") + "." : "none."] Message: [SSshuttle.centcom_message || "none."]", INVESTIGATE_CARGO)

/*
	Generates a box of mail depending on our exports and imports.
	Applied in the cargo shuttle sending/arriving, by building the crate if the round is ready to introduce mail based on the economy subsystem.
	Then, fills the mail crate with mail, by picking applicable crew who can recieve mail at the time to sending.
*/
/obj/docking_port/mobile/supply/proc/create_mail()
	//Early return if there's no mail waiting to prevent taking up a slot. We also don't send mails on sundays or holidays.
	if(!SSeconomy.mail_waiting || SSeconomy.mail_blocked)
		return

	//spawn crate
	var/list/empty_turfs = list()
	for(var/place as anything in shuttle_areas)
		var/area/shuttle/shuttle_area = place
		for(var/turf/open/floor/shuttle_floor in shuttle_area)
			if(shuttle_floor.is_blocked_turf())
				continue
			empty_turfs += shuttle_floor

	new /obj/structure/closet/crate/mail/economy(pick(empty_turfs))

#undef GOODY_FREE_SHIPPING_MAX
#undef CRATE_TAX