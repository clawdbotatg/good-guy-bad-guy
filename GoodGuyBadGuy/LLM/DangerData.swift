import Foundation

/// The curated danger list. Ships in the binary, works with zero bars.
///
/// This is the app's source of truth for "is it harmful" — see `DangerTable`
/// for why the model is never asked. Entries err toward warning: where a
/// harmless species shares a name or a look with a dangerous one, the
/// dangerous entry is the one that fires.
///
/// `names` are matched whole-word and case-insensitively against the model's
/// identification. Include the common name, the genus, and regional names.
/// Never use an alias that is a word inside another word ("ant" would match
/// "plant"); write "fire ant".
///
/// `note` is printed to the user verbatim as the authoritative answer, so it
/// must be factually correct and short. Coverage priorities, in order:
/// medically significant venomous animals, plants that kill pets (the reason
/// this table exists), deadly mushrooms, then the common harmless species
/// people actually photograph.
extension DangerTable {
    static let json = """
        [
        {"names":["lily","lilium","daylily","day lily","hemerocallis","easter lily","tiger lily","asiatic lily","stargazer lily","oriental lily","wood lily"],
         "category":"plant","verdict":"bad",
         "note":"Deadly to cats. Every part — petals, leaves, pollen, even vase water — can cause fatal kidney failure, and a nibble or a lick of pollen off the fur is enough. Dogs get mild stomach upset; people are not seriously at risk. If a cat may have touched it, this is an emergency: call a vet now."},

        {"names":["sago palm","cycad","cycas","zamia","coontie"],
         "category":"plant","verdict":"bad",
         "note":"Severely toxic to dogs and cats — the seeds most of all. Causes liver failure and is often fatal even with treatment. Seek veterinary care immediately if a pet chewed any part."},

        {"names":["oleander","nerium"],
         "category":"plant","verdict":"bad",
         "note":"Every part is poisonous to people and pets — it disrupts the heart rhythm, and a small amount can kill. Do not eat it, and never burn it or use the sticks for skewers."},

        {"names":["foxglove","digitalis"],
         "category":"plant","verdict":"bad",
         "note":"Contains heart-stopping cardiac glycosides. Poisonous to people, dogs, and cats if eaten, even in small amounts."},

        {"names":["azalea","rhododendron"],
         "category":"plant","verdict":"bad",
         "note":"Toxic to dogs, cats, and horses; a few leaves can cause vomiting, collapse, and heart problems. Also poisonous to people, including honey made from the nectar."},

        {"names":["poison ivy","toxicodendron radicans"],
         "category":"plant","verdict":"bad",
         "note":"Its oil (urushiol) causes a blistering rash on contact, and the rash can come from touching pets, tools, or clothes that brushed it. Leaves of three — do not touch, and never burn it, since the smoke injures the lungs."},

        {"names":["poison oak","toxicodendron diversilobum","toxicodendron pubescens"],
         "category":"plant","verdict":"bad",
         "note":"Same rash-causing oil as poison ivy, on oak-shaped leaves. Do not touch, and never burn it."},

        {"names":["poison sumac","toxicodendron vernix"],
         "category":"plant","verdict":"bad",
         "note":"More potent than poison ivy; causes a severe blistering rash. Grows in wet, boggy ground. Do not touch or burn."},

        {"names":["virginia creeper","parthenocissus quinquefolia","woodbine"],
         "category":"plant","verdict":"good",
         "note":"A harmless poison-ivy look-alike. The tell: five leaflets radiating from one point, not poison ivy's three. Safe to be around, but don't eat the blue-black berries — they're mildly toxic if swallowed."},

        {"names":["box elder","boxelder","acer negundo"],
         "category":"plant","verdict":"good",
         "note":"A harmless native maple whose seedlings mimic poison ivy. The tell: box elder leaves grow in opposite pairs on the stem, while poison ivy's are staggered (alternate). Not toxic to touch."},

        {"names":["bramble","brambles"],
         "category":"plant","verdict":"good",
         "note":"A harmless blackberry/raspberry relative, sometimes mistaken for poison ivy. The tell: brambles have thorns or prickles on the stems — poison ivy never does. Watch the thorns, but it won't give you a rash."},

        {"names":["fragrant sumac","rhus aromatica"],
         "category":"plant","verdict":"good",
         "note":"A harmless shrub with leaves of three that people confuse with poison ivy and poison oak. It's a different genus (Rhus, not the rash-causing Toxicodendron) and does not cause a rash."},

        {"names":["staghorn sumac","rhus typhina"],
         "category":"plant","verdict":"good",
         "note":"A harmless roadside shrub, not poison sumac. The tell: staghorn sumac has upright, cone-shaped clusters of fuzzy red berries, while poison sumac has drooping white-green berries and grows only in wet bogs."},

        {"names":["jack-in-the-pulpit","jack in the pulpit","arisaema triphyllum","arisaema"],
         "category":"plant","verdict":"good",
         "note":"A harmless woodland wildflower with three leaflets that gets mistaken for poison ivy. Safe to be around and touch, but don't eat any part — it contains calcium-oxalate crystals that burn the mouth."},

        {"names":["hog peanut","hog-peanut","amphicarpaea bracteata","amphicarpaea"],
         "category":"plant","verdict":"good",
         "note":"A harmless native vine with leaves of three, a common poison-ivy look-alike. It has delicate pale flowers and does not cause a rash."},

        {"names":["giant hogweed","heracleum mantegazzianum"],
         "category":"plant","verdict":"bad",
         "note":"Sap plus sunlight causes third-degree chemical burns and can blind you if it reaches the eyes. Do not touch it; if sap contacts skin, wash it off, keep the area out of sunlight, and see a doctor."},

        {"names":["water hemlock","cicuta","cowbane"],
         "category":"plant","verdict":"bad",
         "note":"One of the most poisonous plants in North America — a mouthful of root can kill an adult. It resembles edible wild carrot and parsnip. Never forage in this family."},

        {"names":["poison hemlock","conium maculatum"],
         "category":"plant","verdict":"bad",
         "note":"Deadly if eaten, and it mimics wild carrot and parsley. The purple-blotched stem is the tell. Do not taste anything in this family."},

        {"names":["deadly nightshade","belladonna","atropa"],
         "category":"plant","verdict":"bad",
         "note":"Highly poisonous to people and pets; the shiny black berries are the most tempting and most dangerous part. A handful can kill a child."},

        {"names":["castor bean","ricinus","castor oil plant"],
         "category":"plant","verdict":"bad",
         "note":"The seeds contain ricin — a few chewed beans can be lethal to a person or a dog. Do not handle the seeds around children or pets."},

        {"names":["jimsonweed","datura","angel trumpet","angels trumpet","brugmansia","devil snare","thorn apple"],
         "category":"plant","verdict":"bad",
         "note":"Every part is strongly poisonous and deliriant; poisonings are frequently fatal and the dose is unpredictable. Dangerous to people, dogs, and cats."},

        {"names":["monkshood","aconitum","wolfsbane","wolf bane","aconite"],
         "category":"plant","verdict":"bad",
         "note":"One of the deadliest garden plants — the toxin passes through skin, so even handling the roots barehanded is risky. Do not touch or eat any part."},

        {"names":["autumn crocus","colchicum","meadow saffron"],
         "category":"plant","verdict":"bad",
         "note":"Contains colchicine; poisoning resembles arsenic and is often fatal to people and pets. Not the same as harmless spring crocus."},

        {"names":["yew","taxus"],
         "category":"plant","verdict":"bad",
         "note":"Needles and seeds are lethal to people, dogs, cats, and horses — sudden cardiac arrest, often with no earlier symptoms. Only the red flesh of the berry is non-toxic, and the seed inside is not."},

        {"names":["lily of the valley","convallaria"],
         "category":"plant","verdict":"bad",
         "note":"Cardiac glycosides throughout the plant, including the water in its vase. Poisonous to people, dogs, and cats."},

        {"names":["manchineel","hippomane mancinella"],
         "category":"plant","verdict":"bad",
         "note":"Possibly the most dangerous tree on earth: the sap blisters skin, blinds eyes, and the fruit is lethal. Do not touch it, eat it, or shelter under it in rain."},

        {"names":["pokeweed","phytolacca"],
         "category":"plant","verdict":"bad",
         "note":"Roots, leaves, and the tempting purple berries are poisonous to people and pets. Children have died from eating the berries."},

        {"names":["larkspur","delphinium"],
         "category":"plant","verdict":"bad",
         "note":"Toxic to people, pets, and especially cattle; the young plant and seeds are the most potent. Do not eat any part."},

        {"names":["wild parsnip","pastinaca sativa","cow parsnip","heracleum maximum"],
         "category":"plant","verdict":"caution",
         "note":"The sap plus sunlight causes burns and long-lasting dark scars. Do not brush against it barelegged; wash any sap off and stay out of the sun."},

        {"names":["stinging nettle","urtica","wood nettle"],
         "category":"plant","verdict":"caution",
         "note":"Hollow hairs inject an irritant — painful stinging and welts for an hour or two, but not dangerous. Do not touch barehanded."},

        {"names":["dieffenbachia","dumb cane"],
         "category":"plant","verdict":"caution",
         "note":"Chewing it causes intense mouth pain and swelling in people, dogs, and cats — occasionally enough to obstruct breathing. Keep away from pets and toddlers."},

        {"names":["philodendron","pothos","epipremnum","devils ivy","monstera"],
         "category":"plant","verdict":"caution",
         "note":"Calcium oxalate crystals cause painful mouth irritation, drooling, and vomiting in dogs and cats. Rarely fatal, but keep it out of reach."},

        {"names":["peace lily","spathiphyllum","calla lily","zantedeschia"],
         "category":"plant","verdict":"caution",
         "note":"Despite the name these are not true lilies and do not cause kidney failure — but they irritate the mouth and throat of pets that chew them. Keep away from pets."},

        {"names":["tulip","tulipa","hyacinth","daffodil","narcissus","amaryllis"],
         "category":"plant","verdict":"caution",
         "note":"The bulbs are the toxic part; a dog that digs one up can get serious vomiting and heart or breathing trouble. Call a vet if a bulb was eaten."},

        {"names":["aloe vera","aloe"],
         "category":"plant","verdict":"caution",
         "note":"Soothing on human skin, but eating it makes dogs and cats vomit and gives them diarrhea. Keep the plant away from pets."},

        {"names":["hydrangea","wisteria","chrysanthemum","english ivy","hedera helix"],
         "category":"plant","verdict":"caution",
         "note":"Commonly planted, and mildly to moderately poisonous to dogs and cats if eaten. Not usually life-threatening, but worth a vet call."},

        {"names":["milkweed","asclepias"],
         "category":"plant","verdict":"caution",
         "note":"Toxic sap if eaten, and it irritates skin and eyes. Valuable for monarch butterflies — leave it standing, just do not chew it or rub your eyes after handling."},

        {"names":["mistletoe","viscum","phoradendron","holly","ilex"],
         "category":"plant","verdict":"caution",
         "note":"The berries are poisonous to children and pets; a few cause vomiting, and more can be serious. Keep holiday sprigs out of reach."},

        {"names":["dandelion","taraxacum","clover","trifolium"],
         "category":"plant","verdict":"good",
         "note":"Harmless to people and pets, and good forage for bees."},

        {"names":["sunflower","helianthus","rose","rosa","violet","daisy","fern","moss"],
         "category":"plant","verdict":"good",
         "note":"Not toxic to people, dogs, or cats. Rose thorns are the only hazard here."},

        {"names":["blackberry","raspberry","rubus"],
         "category":"plant","verdict":"good",
         "note":"The plant is harmless — just thorny. Confident wild-berry identification is still on you; this app does not judge edibility."},

        {"names":["death cap","amanita phalloides"],
         "category":"mushroom","verdict":"bad",
         "note":"The deadliest mushroom in the world — half a cap kills an adult, symptoms are delayed a day, and by then the liver is failing. Do not eat, and wash your hands after touching."},

        {"names":["destroying angel","amanita bisporigera","amanita ocreata","amanita virosa"],
         "category":"mushroom","verdict":"bad",
         "note":"An all-white Amanita that is lethal in small amounts, with symptoms delayed until liver damage is underway. Deadly, and easily mistaken for edible white mushrooms."},

        {"names":["fly agaric","amanita muscaria","panther cap","amanita pantherina"],
         "category":"mushroom","verdict":"bad",
         "note":"The red-with-white-spots storybook mushroom. Poisonous — causes delirium, seizures, and coma. Dogs are drawn to them and are frequently poisoned."},

        {"names":["galerina","deadly galerina","funeral bell","conocybe","lepiota","deadly webcap","cortinarius"],
         "category":"mushroom","verdict":"bad",
         "note":"Small brown mushrooms carrying the same liver-destroying toxin as the death cap. Lethal, and impossible to tell from harmless brown mushrooms without a microscope."},

        {"names":["false morel","gyromitra"],
         "category":"mushroom","verdict":"bad",
         "note":"Brain-shaped, not honeycombed like a true morel. Contains a rocket-fuel toxin that can be lethal, and the fumes from cooking it are poisonous too."},

        {"names":["jack-o-lantern","jack o lantern","omphalotus","green-spored parasol","chlorophyllum molybdites"],
         "category":"mushroom","verdict":"bad",
         "note":"A notorious poisoner: mistaken for chanterelles or edible parasols and causes violent illness. Do not eat."},

        {"names":["amanita","morel","morchella","chanterelle","puffball","bolete","oyster mushroom","russula","inky cap","psilocybe","shiitake"],
         "category":"mushroom","verdict":"caution",
         "note":"Named genera in this group contain both prized edibles and lethal look-alikes, and a photo cannot tell them apart. Do not eat anything identified this way."},

        {"names":["rattlesnake","crotalus","sistrurus","diamondback","sidewinder","timber rattler","massasauga"],
         "category":"snake","verdict":"bad",
         "note":"Venomous. Back away slowly and give it room — most bites happen when people try to kill, move, or handle one. If bitten, call emergency services and keep the limb still and below the heart."},

        {"names":["copperhead","agkistrodon contortrix"],
         "category":"snake","verdict":"bad",
         "note":"Venomous pit viper; bites are painful and need medical care, though rarely fatal. Back away and leave it alone."},

        {"names":["cottonmouth","water moccasin","agkistrodon piscivorus"],
         "category":"snake","verdict":"bad",
         "note":"Venomous. Often confused with harmless water snakes, so treat any water snake as suspect. Back away; do not corner it."},

        {"names":["coral snake","micrurus","micruroides"],
         "category":"snake","verdict":"bad",
         "note":"Venomous, with a potent neurotoxin. Banded red-yellow-black; harmless king and milk snakes mimic it, so never handle a banded snake to check the rhyme. Bites may cause few symptoms for hours — get medical care immediately."},

        {"names":["cobra","naja","king cobra","ophiophagus"],
         "category":"snake","verdict":"bad",
         "note":"Highly venomous, and some species spit venom into the eyes. Retreat immediately and get well out of striking range."},

        {"names":["black mamba","green mamba","dendroaspis"],
         "category":"snake","verdict":"bad",
         "note":"Extremely venomous and fast. Retreat immediately. A bite is a life-threatening emergency requiring antivenom."},

        {"names":["taipan","oxyuranus","eastern brown snake","pseudonaja","tiger snake","notechis","death adder","acanthophis"],
         "category":"snake","verdict":"bad",
         "note":"Among the most venomous snakes on earth. Back away and do not attempt to catch or kill it. If bitten, apply a pressure immobilization bandage and call emergency services."},

        {"names":["adder","vipera","russells viper","daboia","saw-scaled viper","echis","puff adder","bitis","gaboon viper"],
         "category":"snake","verdict":"bad",
         "note":"Venomous viper. Back away slowly; a bite needs urgent hospital care and antivenom."},

        {"names":["fer-de-lance","bothrops","bushmaster","lachesis","boomslang","dispholidus","sea snake"],
         "category":"snake","verdict":"bad",
         "note":"Dangerously venomous. Leave the area; a bite is a medical emergency."},

        {"names":["pit viper","crotalinae","viper","venomous snake"],
         "category":"snake","verdict":"bad",
         "note":"Venomous. Back away slowly and give it space. Do not try to move or kill it — that is when most bites happen."},

        {"names":["garter snake","thamnophis","ribbon snake"],
         "category":"snake","verdict":"good",
         "note":"Harmless and non-venomous; it eats slugs and rodents. It may musk or nip if grabbed — so do not grab it."},

        {"names":["rat snake","pantherophis","corn snake","king snake","lampropeltis","milk snake","gopher snake","pituophis","bull snake","hognose","heterodon","ring-necked snake","racer","coluber","water snake","nerodia"],
         "category":"snake","verdict":"good",
         "note":"Non-venomous and beneficial — these eat rodents, and some eat venomous snakes. Several mimic vipers by flattening or rattling their tail. Watch it leave; do not handle it."},

        {"names":["black widow","latrodectus","redback","katipo","brown widow"],
         "category":"spider","verdict":"bad",
         "note":"Venomous. Glossy black with a red hourglass underneath. Bites cause severe cramping pain and need medical care; deaths are rare. Shake out shoes, gloves, and firewood that sat outdoors."},

        {"names":["brown recluse","loxosceles","violin spider","fiddleback","six-eyed sand spider","sicarius"],
         "category":"spider","verdict":"bad",
         "note":"Venomous. Its bite can destroy tissue and heal badly over weeks. Seek medical care. Recluses hide in stored clothes, boxes, and bedding — shake things out."},

        {"names":["funnel-web","funnel web","atrax","hadronyche","sydney funnel-web"],
         "category":"spider","verdict":"bad",
         "note":"One of the most dangerous spiders alive; bites can kill within hours without antivenom. Do not approach. If bitten, apply a pressure immobilization bandage and call emergency services."},

        {"names":["brazilian wandering spider","phoneutria","banana spider"],
         "category":"spider","verdict":"bad",
         "note":"Highly venomous and aggressive when cornered. Do not approach; a bite requires immediate hospital care."},

        {"names":["hobo spider","eratigena agrestis","yellow sac spider","cheiracanthium","mouse spider","missulena","tarantula"],
         "category":"spider","verdict":"caution",
         "note":"Bites are painful but not considered life-threatening; tarantulas also flick irritating hairs that hurt eyes. Leave it alone rather than handling it."},

        {"names":["wolf spider","lycosidae","jumping spider","salticidae","orb weaver","araneidae","garden spider","argiope","cellar spider","pholcus","daddy long legs","daddy longlegs","harvestman","opiliones","house spider","crab spider","huntsman","grass spider"],
         "category":"spider","verdict":"good",
         "note":"Harmless to people — no medically significant venom — and a free pest-control service. It will run from you. Leave it be, or cup-and-card it outside."},

        {"names":["arizona bark scorpion","centruroides","deathstalker","leiurus","fat-tailed scorpion","androctonus","tityus"],
         "category":"scorpion","verdict":"bad",
         "note":"Medically significant venom — dangerous to children, the elderly, and pets. Seek medical care after a sting. Shake out shoes and bedding in scorpion country."},

        {"names":["scorpion","emperor scorpion","pandinus"],
         "category":"scorpion","verdict":"caution",
         "note":"Most scorpion stings hurt like a bad wasp sting and nothing worse, but a few species are dangerous and they are hard to tell apart. Do not handle it; get medical advice if a child or pet is stung."},

        {"names":["kissing bug","triatoma","assassin bug"],
         "category":"insect","verdict":"bad",
         "note":"Can transmit Chagas disease, a lifelong heart infection, and its bite is painful. Do not squash it against your skin. Trap it in a container if you can, for testing."},

        {"names":["tick","ixodes","deer tick","lone star tick","dog tick","blacklegged tick"],
         "category":"insect","verdict":"bad",
         "note":"Carries Lyme disease and other serious infections. Remove it promptly with fine tweezers, gripping close to the skin and pulling straight out — then watch for a rash or fever and see a doctor if either appears."},

        {"names":["asian giant hornet","vespa mandarinia","murder hornet","northern giant hornet","africanized honey bee","killer bee"],
         "category":"insect","verdict":"bad",
         "note":"Dangerous in numbers — multiple stings can be lethal even to people who are not allergic. Do not disturb the nest; move away calmly and get well clear."},

        {"names":["puss caterpillar","megalopyge","saddleback caterpillar","acharia","io moth caterpillar","buck moth caterpillar","browntail moth","brown-tail moth"],
         "category":"insect","verdict":"bad",
         "note":"Venomous spines under the fur cause searing pain, and some people react severely. Never touch a fuzzy or spiny caterpillar. Lift spines out with tape and seek care if pain spreads."},

        {"names":["bullet ant","paraponera"],
         "category":"insect","verdict":"bad",
         "note":"The most painful insect sting known, lasting many hours. Back away from the nest."},

        {"names":["fire ant","solenopsis"],
         "category":"insect","verdict":"caution",
         "note":"Swarms and stings repeatedly, leaving pustules; dangerous to people who are allergic, and to small pets caught in a mound. Move away from the mound and brush them off fast."},

        {"names":["yellowjacket","yellow jacket","vespula","hornet","vespa","paper wasp","polistes","wasp","honey bee","honeybee","apis mellifera","bumblebee","bumble bee"],
         "category":"insect","verdict":"caution",
         "note":"Stings hurt, and can be life-threatening if you are allergic — carry epinephrine if you know you are. Bees are gentle away from the hive; wasps defend nests aggressively. Do not swat near a nest."},

        {"names":["blister beetle","meloidae","centipede","scolopendra"],
         "category":"insect","verdict":"caution",
         "note":"Can burn or bite painfully if handled or crushed against skin — large centipede bites are agonizing but not usually dangerous. Do not pick it up."},

        {"names":["mosquito","black fly","horsefly","chigger","bed bug","biting midge"],
         "category":"insect","verdict":"caution",
         "note":"A biting nuisance that can carry disease depending on the region. Cover up and use repellent."},

        {"names":["ladybug","ladybird","coccinellidae","butterfly","monarch","dragonfly","damselfly","praying mantis","mantis","grasshopper","cricket","cicada","firefly","lightning bug","moth","beetle","june bug","stink bug","aphid","carpenter ant","pill bug","roly poly","isopod","millipede","earthworm","snail","slug","water strider","house centipede","woolly bear","hornworm"],
         "category":"insect","verdict":"good",
         "note":"Harmless to people and pets. Most of these eat pests or pollinate — worth leaving alone."},

        {"names":["gila monster","heloderma","beaded lizard"],
         "category":"other","verdict":"bad",
         "note":"Venomous lizard with a locking bite. Do not approach or handle it; a bite needs medical care."},

        {"names":["cone snail","conus","blue-ringed octopus","hapalochlaena","box jellyfish","chironex","stonefish","synanceia"],
         "category":"other","verdict":"bad",
         "note":"Among the most venomous animals in the sea, and capable of killing a person. Do not touch or pick it up. A sting or bite is an immediate emergency."},

        {"names":["portuguese man o war","man o war","physalia","lionfish","pterois","stingray","pufferfish","sea urchin","fire coral","jellyfish"],
         "category":"other","verdict":"caution",
         "note":"Stings or spines that cause severe pain, and some are dangerous. Do not touch, even when washed up dead — tentacles still fire. Get medical help if stung badly."},

        {"names":["cane toad","rhinella marina","colorado river toad","incilius alvarius","poison dart frog","dendrobates","rough-skinned newt","taricha"],
         "category":"other","verdict":"bad",
         "note":"Secretes toxin through its skin. Deadly to dogs that mouth it — rinse the dog's mouth sideways with water and go to a vet immediately. Wash your hands after any contact."},

        {"names":["alligator","crocodile","caiman","snapping turtle"],
         "category":"other","verdict":"bad",
         "note":"Capable of severe injury. Keep well back from the water's edge, keep pets leashed, and never feed it."},

        {"names":["grizzly","brown bear","black bear","mountain lion","cougar","puma","wolf","moose","bison"],
         "category":"mammal","verdict":"bad",
         "note":"Large and capable of killing. Do not run or approach: back away slowly, make yourself large, keep children and pets close. Store food away from camp."},

        {"names":["raccoon","skunk","bat","coyote","fox"],
         "category":"mammal","verdict":"caution",
         "note":"Rabies risk, especially if it is active in daylight, unafraid, or stumbling. Do not approach or feed it. Any bite or bat found in a bedroom needs immediate medical advice."},

        {"names":["deer","squirrel","rabbit","chipmunk","frog","toad","lizard","gecko","skink","turtle","box turtle","salamander","newt"],
         "category":"other","verdict":"good",
         "note":"Harmless if left alone. Wash your hands after any contact — reptiles and amphibians commonly carry salmonella."}
        ]
        """
}
