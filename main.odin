package jumper

import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:mem"
import "core:image/png"
import "core:strings"
import "core:time"

import b2d "vendor:box2d"
import "vendor:cgltf"

import "sm:core"
import "sm:platform"
import "sm:rhi"
import r2im "sm:renderer/2d_immediate"

SIXTY_FPS_DT :: 1.0 / 60.0
WORLD_TO_PIXEL :: 50.0
PIXEL_TO_WORLD :: 1.0/WORLD_TO_PIXEL

Matrix4 :: matrix[4, 4]f32
Vec2 :: [2]f32
Vec3 :: [3]f32
Vec4 :: [4]f32

main :: proc() {
	core.g_root_dir = "Spelmotor"

	// For error handling
	ok: bool

	// Setup tracking allocator
	when ODIN_DEBUG {
		t: mem.Tracking_Allocator
		mem.tracking_allocator_init(&t, context.allocator)
		context.allocator = mem.tracking_allocator(&t)

		defer {
			log.debugf("Total memory allocated: %i", t.total_memory_allocated)
			log.debugf("Total memory freed: %i", t.total_memory_freed)
			if len(t.allocation_map) > 0 {
				log.fatalf("%i allocations not freed!", len(t.allocation_map))
				for _, entry in t.allocation_map {
					log.errorf(" * %m at %s", entry.size, entry.location)
				}
			}
			if len(t.bad_free_array) > 0 {
				log.fatalf("%i incorrect frees!", len(t.bad_free_array))
				for entry in t.bad_free_array {
					log.errorf(" * at %s", entry.location)
				}
			}
			mem.tracking_allocator_destroy(&t)
		}
	}

	// Setup logger
	context.logger = core.create_engine_logger()
	context.assertion_failure_proc = core.assertion_failure

	// Listen to platform events
	platform.shared_data.event_callback_proc = proc(window: platform.Window_Handle, event: platform.System_Event) {
		rhi.process_platform_events(window, event)

		#partial switch e in event {
		case platform.Key_Event:
			#partial switch e.keycode {
			case .Space:
				if e.type == .Pressed {
					player_jump()
				}
			case .A:
				g_input_state.input_left = e.type != .Released
			case .D:
				g_input_state.input_right = e.type != .Released
			}
		}
	}

	// Init platform
	if !platform.init() {
		log.fatal("The main application could not initialize the platform layer.")
		return
	}
	defer platform.shutdown()

	main_window: platform.Window_Handle
	window_desc := platform.Window_Desc{
		width = 1280, height = 720,
		position = nil,
		title = "Jumper",
		fixed_size = true,
	}
	if main_window, ok = platform.create_window(window_desc); !ok {
		log.fatal("The main application window could not be created.")
		return
	}

	platform.register_raw_input_devices()

	// Init the RHI
	rhi_init := rhi.RHI_Init{
		main_window_handle = main_window,
		app_name = "Jumper",
		ver = {1, 0, 0},
	}
	if r := rhi.init(rhi_init); r != nil {
		rhi.handle_error(&r.(rhi.RHI_Error))
		log.fatal(r.(rhi.RHI_Error).error_message)
		return
	}
	defer {
		rhi.wait_for_device()
		rhi.shutdown()
	}

	// An RHI surface will be created automatically for the main window

	r2im_res := r2im.init()
	defer r2im.shutdown()
	if r2im_res != nil {
		r2im.log_result(r2im_res)
		return
	}

	// Finally, show the main window
	platform.show_window(main_window)

	// Free after initialization
	free_all(context.temp_allocator)

	// Create Box2d world
	world_def := b2d.DefaultWorldDef()
	world_def.gravity = Vec2{0, WORLD_GRAVITY}
	g_b2d_state.world = b2d.CreateWorld(world_def)
	defer b2d.DestroyWorld(g_b2d_state.world)

	// Create ground as a static body
	ground_def := b2d.DefaultBodyDef()
	ground_def.position = Vec2{0, -7}
	g_b2d_state.ground = b2d.CreateBody(g_b2d_state.world, ground_def)
	defer b2d.DestroyBody(g_b2d_state.ground)

	// Set ground polygon shape
	ground_shape_def := b2d.DefaultShapeDef()
	ground_shape_def.restitution = GROUND_RESTITUTION
	ground_shape_def.friction = 0.1
	ground_shape_def.filter.categoryBits = cast(u32) Box2d_Categories{.STATIC}
	ground_box := b2d.MakeBox(50, 0.5)
	ground_shape_id := b2d.CreatePolygonShape(g_b2d_state.ground, ground_shape_def, ground_box)

	// Create walls as static bodies
	lwall_def := b2d.DefaultBodyDef()
	lwall_def.position = Vec2{-13, 0}
	g_b2d_state.lwall = b2d.CreateBody(g_b2d_state.world, lwall_def)
	defer b2d.DestroyBody(g_b2d_state.lwall)
	rwall_def := b2d.DefaultBodyDef()
	rwall_def.position = Vec2{13, 0}
	g_b2d_state.rwall = b2d.CreateBody(g_b2d_state.world, rwall_def)
	defer b2d.DestroyBody(g_b2d_state.rwall)

	// Set wall polygon shapes
	wall_shape_def := b2d.DefaultShapeDef()
	wall_shape_def.restitution = WALL_RESTITUTION
	wall_shape_def.filter.categoryBits = cast(u32) Box2d_Categories{.STATIC}
	wall_box := b2d.MakeBox(0.5, 50)
	_ = b2d.CreatePolygonShape(g_b2d_state.lwall, wall_shape_def, wall_box)
	_ = b2d.CreatePolygonShape(g_b2d_state.rwall, wall_shape_def, wall_box)

	// Create player as a Box2d dynamic body
	player_def := b2d.DefaultBodyDef()
	player_def.type = .dynamicBody
	player_def.position = Vec2{0, 0}
	player_def.angularVelocity = 0.5 * math.TAU
	player_def.linearVelocity = Vec2{2, 0}
	g_b2d_state.player = b2d.CreateBody(g_b2d_state.world, player_def)
	defer b2d.DestroyBody(g_b2d_state.player)

	// Set player polygon shape
	player_shape_def := b2d.DefaultShapeDef()
	player_shape_def.density = 1
	player_shape_def.friction = 0.1
	player_shape_def.filter.categoryBits = cast(u32) Box2d_Categories{.PLAYER}
	player_shape_def.filter.maskBits = cast(u32) Box2d_Categories{.STATIC, .BOX, .PICKUP}
	player_polygon := b2d.MakeBox(0.5, 0.5)
	player_shape_id := b2d.CreatePolygonShape(g_b2d_state.player, player_shape_def, player_polygon)

	init_game_state()
	defer destroy_game_state()

	defer destroy_box2d_state()

	dt := f64(SIXTY_FPS_DT)
	last_now := time.tick_now()

	// Game loop
	for platform.pump_events() {
		update(dt)
		draw()

		// Free on frame end
		free_all(context.temp_allocator)

		now := time.tick_now()
		dt = time.duration_seconds(time.tick_diff(last_now, now))
		if dt > 1 {
			dt = SIXTY_FPS_DT
		}
		last_now = now
	}
}

WORLD_GRAVITY :: -15.0

WALL_RESTITUTION :: 0.6
GROUND_RESTITUTION :: 0.3

PLAYER_SIZE :: 1.0
PLAYER_PIXEL_SIZE :: PLAYER_SIZE * WORLD_TO_PIXEL
PLAYER_HORIZONTAL_MOVEMENT_FORCE :: 2000
PLAYER_JUMP_FORCE :: 1300
PLAYER_MAX_LIVES :: 5

BOX_SIZE :: Vec2{2, 4}

NO_SPAWN_ZONE_LEEWAY :: 0.4

Range :: struct {min, max: f32}

Box2d_State :: struct {
	world: b2d.WorldId,
	ground: b2d.BodyId,
	lwall: b2d.BodyId,
	rwall: b2d.BodyId,
	player: b2d.BodyId,
	boxes: [dynamic]b2d.BodyId,
	hearts: [dynamic]b2d.BodyId,
}
g_b2d_state: Box2d_State

Box2d_Categories :: distinct bit_set[Box2d_Category; u32]
Box2d_Category :: enum u32 {
	STATIC,
	BOX,
	PICKUP,
	PLAYER,
}

Object_Type :: enum {
	BOX,
	HEART,
}

Body_User_Data :: struct {
	object_type: Object_Type,
}

destroy_boxes :: proc() {
	for box in g_b2d_state.boxes {
		user_data := cast(^Body_User_Data) b2d.Body_GetUserData(box)
		assert(user_data != nil)
		free(user_data)
		b2d.DestroyBody(box)
	}
	clear(&g_b2d_state.boxes)
}

destroy_hearts :: proc() {
	for heart in g_b2d_state.hearts {
		user_data := cast(^Body_User_Data) b2d.Body_GetUserData(heart)
		assert(user_data != nil)
		free(user_data)
		b2d.DestroyBody(heart)
	}
	clear(&g_b2d_state.hearts)
}

destroy_box2d_state :: proc() {
	destroy_boxes()
	delete(g_b2d_state.boxes)
	destroy_hearts()
	delete(g_b2d_state.hearts)
}

Input_State :: struct {
	input_right: bool,
	input_left: bool,
}
g_input_state: Input_State

Scheduled_Spawn :: struct {
	type: Object_Type,
	time_to_spawn: f64,
	velocity: Vec2,
	x_pos: f32,
}

Game_State :: struct {
	time: f64,

	last_box_spawn_time: f64,
	box_spawn_interval: f64,
	boxes_to_spawn: u32,
	is_spawning_boxes: bool,
	scheduled_spawns: [dynamic]Scheduled_Spawn,

	score: i32,

	player_was_hit: bool,
	player_lives: u32,
	player_lost: bool,

	debug_no_spawn_zone: Range,
}
g_game_state: Game_State

init_game_state :: proc() {
	g_game_state = {}
	g_game_state.box_spawn_interval = 3
	g_game_state.boxes_to_spawn = 1
	g_game_state.player_lives = 5
}

destroy_game_state :: proc() {
	delete(g_game_state.scheduled_spawns)
}

// Kinda hacky but will work for now
player_is_on_ground :: proc() -> bool {
	player_pos := b2d.Body_GetPosition(g_b2d_state.player)
	query_filter: b2d.QueryFilter
	query_filter.categoryBits = cast(u32) Box2d_Categories{.PLAYER}
	query_filter.maskBits = cast(u32) Box2d_Categories{.STATIC}
	ray_result := b2d.World_CastRayClosest(g_b2d_state.world, player_pos, Vec2{0, -1}, query_filter)
	return ray_result.hit
}

player_jump :: proc() {
	if !player_is_on_ground() || g_game_state.player_lost {
		return
	}

	player_pos := b2d.Body_GetPosition(g_b2d_state.player)
	b2d.Body_ApplyForce(g_b2d_state.player, Vec2{0, PLAYER_JUMP_FORCE}, player_pos, true)
}

begin_wave :: proc() {
	clear(&g_game_state.scheduled_spawns)

	// Calc the no-spawn zone
	player_pos := b2d.Body_GetPosition(g_b2d_state.player)
	direction: f32 = 1 if rand.float32_range(-11, 11) > player_pos.x else -1
	distance := rand.float32_range(4, 10)
	no_spawn_zone_center := math.clamp(player_pos.x + distance * direction, -11, 11)
	no_spawn_zone := Range{
		min = no_spawn_zone_center - ((BOX_SIZE.x/2) + (PLAYER_SIZE/2) + (NO_SPAWN_ZONE_LEEWAY/2)),
		max = no_spawn_zone_center + ((BOX_SIZE.x/2) + (PLAYER_SIZE/2) + (NO_SPAWN_ZONE_LEEWAY/2)),
	}
	is_l_range_available := no_spawn_zone.min > -11
	is_r_range_available := no_spawn_zone.max < 11
	are_both_ranges_available := is_l_range_available && is_r_range_available
	assert(is_l_range_available || is_r_range_available)

	g_game_state.debug_no_spawn_zone = no_spawn_zone

	heart_spawned := false
	for i in 0..<g_game_state.boxes_to_spawn {
		// Randomize the position between the ranges split by the no-spawn zone
		box_x_pos: f32
		Range_Type :: enum {LEFT, RIGHT}
		range_min, range_max: f32
		if are_both_ranges_available {
			switch rand.choice_enum(Range_Type) {
			case .LEFT:
				box_x_pos = rand.float32_range(-11, no_spawn_zone.min)
			case .RIGHT:
				box_x_pos = rand.float32_range(no_spawn_zone.max, 11)
			}
		} else if is_l_range_available {
			box_x_pos = rand.float32_range(-11, no_spawn_zone.min)
		} else {
			assert(is_r_range_available)
			box_x_pos = rand.float32_range(no_spawn_zone.max, 11)
		}

		box_velocity: Vec2
		box_velocity.y = rand.float32_range(-3, 0)
		box_velocity.x = rand.float32_range(-0.2, 0.2)

		// Spawn the boxes later sequentially
		spawn_data := Scheduled_Spawn{
			type = .BOX,
			time_to_spawn = 0.2,
			velocity = box_velocity,
			x_pos = box_x_pos,
		}
		append(&g_game_state.scheduled_spawns, spawn_data)

		// Sometimes also spawn a heart
		if !heart_spawned && g_game_state.player_lives < PLAYER_MAX_LIVES {
			if rand.float32() < 0.2 {
				spawn_data := Scheduled_Spawn{
					type = .HEART,
					time_to_spawn = 0,
					velocity = Vec2{},
					x_pos = no_spawn_zone_center,
				}
				append(&g_game_state.scheduled_spawns, spawn_data)
				heart_spawned = true
			}
		}
	}
}

spawn_box :: proc(data: Scheduled_Spawn) {
	// Create boxes as Box2d dynamic bodies
	box_def := b2d.DefaultBodyDef()
	box_def.type = .dynamicBody
	box_def.position = Vec2{data.x_pos, 20}
	box_def.linearVelocity = data.velocity
	box_user_data := new(Body_User_Data)
	box_user_data.object_type = .BOX
	box_def.userData = box_user_data
	box_id := b2d.CreateBody(g_b2d_state.world, box_def)

	// Set box polygon shape
	box_shape_def := b2d.DefaultShapeDef()
	box_shape_def.density = 1
	box_shape_def.friction = 0
	box_shape_def.filter.categoryBits = cast(u32) Box2d_Categories{.BOX}
	box_shape_def.filter.maskBits = cast(u32) Box2d_Categories{.PLAYER}
	box_shape_def.enableHitEvents = true
	box_polygon := b2d.MakeBox(BOX_SIZE.x/2, BOX_SIZE.y/2)
	_ = b2d.CreatePolygonShape(box_id, box_shape_def, box_polygon)

	append(&g_b2d_state.boxes, box_id)

	g_game_state.last_box_spawn_time = g_game_state.time
}

spawn_heart :: proc(data: Scheduled_Spawn) {
	// Create a heart as a Box2d dynamic body
	heart_def := b2d.DefaultBodyDef()
	heart_def.type = .dynamicBody
	heart_def.position = Vec2{data.x_pos, 20}
	heart_def.linearVelocity = data.velocity
	heart_def.gravityScale = 0.5
	heart_user_data := new(Body_User_Data)
	heart_user_data.object_type = .HEART
	heart_def.userData = heart_user_data
	heart_id := b2d.CreateBody(g_b2d_state.world, heart_def)

	// Set box polygon shape
	heart_shape_def := b2d.DefaultShapeDef()
	heart_shape_def.density = 1
	heart_shape_def.friction = 0
	heart_shape_def.filter.categoryBits = cast(u32) Box2d_Categories{.PICKUP}
	heart_shape_def.filter.maskBits = cast(u32) Box2d_Categories{.PLAYER}
	heart_shape_def.enableHitEvents = true
	heart_polygon := b2d.MakeBox(PLAYER_SIZE/2, PLAYER_SIZE/2)
	_ = b2d.CreatePolygonShape(heart_id, heart_shape_def, heart_polygon)

	append(&g_b2d_state.hearts, heart_id)

	g_game_state.last_box_spawn_time = g_game_state.time
}

update :: proc(dt: f64) {
	g_game_state.time += dt

	// Begin waves at a set interval
	if !g_game_state.player_lost && !g_game_state.is_spawning_boxes && g_game_state.time - g_game_state.last_box_spawn_time >= g_game_state.box_spawn_interval {
		log.infof("Spawning %i boxes.", g_game_state.boxes_to_spawn)
		g_game_state.is_spawning_boxes = true

		destroy_boxes()
		destroy_hearts()

		if g_game_state.boxes_to_spawn > 1 {
			g_game_state.score += 1
			log.info("Score:", g_game_state.score)
		}

		g_game_state.player_was_hit = false
		begin_wave()
		g_game_state.boxes_to_spawn += 1
	}

	// Spawn entities
	if g_game_state.is_spawning_boxes {
		assert(len(g_game_state.scheduled_spawns) > 0)
		spawn := &g_game_state.scheduled_spawns[len(g_game_state.scheduled_spawns)-1]
		spawn.time_to_spawn -= dt
		if spawn.time_to_spawn <= 0 {
			spawn_data := pop(&g_game_state.scheduled_spawns)
			switch spawn_data.type {
			case .BOX:
				spawn_box(spawn_data)
			case .HEART:
				spawn_heart(spawn_data)
			}
		}
		if len(g_game_state.scheduled_spawns) == 0 {
			g_game_state.is_spawning_boxes = false
		}
	}

	// Apply player movement force
	if player_is_on_ground() && !g_game_state.player_lost {
		player_pos := b2d.Body_GetPosition(g_b2d_state.player)
		l_force := -PLAYER_HORIZONTAL_MOVEMENT_FORCE * f32(uint(g_input_state.input_left))
		r_force :=  PLAYER_HORIZONTAL_MOVEMENT_FORCE * f32(uint(g_input_state.input_right))
		player_force := Vec2{l_force + r_force, 0} * f32(dt)
		b2d.Body_ApplyForce(g_b2d_state.player, player_force, player_pos, true)
	}

	// Step world simulation
	b2d.World_Step(g_b2d_state.world, cast(f32) dt, 4)

	// Handle hit events
	contact_events := b2d.World_GetContactEvents(g_b2d_state.world)
	for i in 0..<contact_events.beginCount {
		begin_contact_event := contact_events.beginEvents[i]
		body_a := b2d.Shape_GetBody(begin_contact_event.shapeIdA)
		body_b := b2d.Shape_GetBody(begin_contact_event.shapeIdB)
		body_a_is_player := body_a == g_b2d_state.player
		body_b_is_player := body_b == g_b2d_state.player
		if body_a_is_player || body_b_is_player {
			other_body := body_a if body_b_is_player else body_b
			other_body_user_data := cast(^Body_User_Data) b2d.Body_GetUserData(other_body)

			if other_body_user_data != nil {
				if other_body_user_data.object_type == .HEART {
					// TODO: Would be better to just destroy that one heart
					destroy_hearts()
					if g_game_state.player_lives < PLAYER_MAX_LIVES {
						g_game_state.player_lives += 1
					}
				}
			}
		}
	}
	for i in 0..<contact_events.hitCount {
		hit_event := contact_events.hitEvents[i]
		body_a := b2d.Shape_GetBody(hit_event.shapeIdA)
		body_b := b2d.Shape_GetBody(hit_event.shapeIdB)
		body_a_is_player := body_a == g_b2d_state.player
		body_b_is_player := body_b == g_b2d_state.player
		if body_a_is_player || body_b_is_player {
			other_body := body_a if body_b_is_player else body_b
			other_body_user_data := cast(^Body_User_Data) b2d.Body_GetUserData(other_body)

			if other_body_user_data != nil {
				if other_body_user_data.object_type == .BOX {
					// Handle falling box hit event
					if hit_event.approachSpeed > 5 {
						abs_dot := math.abs(linalg.dot(hit_event.normal, Vec2{0, 1}))
						if abs_dot > 0.8 {
							if !g_game_state.player_was_hit {
								g_game_state.player_lives -= 1
								if g_game_state.player_lives == 0 {
									g_game_state.player_lost = true
								}
		
								g_game_state.score -= 5
								if g_game_state.score < 0 {
									g_game_state.score = 0
								}
		
								// Postpone the next spawn
								g_game_state.last_box_spawn_time = g_game_state.time
								g_game_state.player_was_hit = true
		
								// Terminate the current wave
								clear(&g_game_state.scheduled_spawns)
								g_game_state.is_spawning_boxes = false
							}
						}
					}
				}
			}
		}
	}
}

draw :: proc() {
	if r2im.begin_frame() {
		// Draw ground
		ground_pos := b2d.Body_GetPosition(g_b2d_state.ground)
		r2im.draw_sprite(ground_pos * WORLD_TO_PIXEL, 0, {100*WORLD_TO_PIXEL, 1*WORLD_TO_PIXEL}, core.path_make_engine_textures_relative("white.png"), {.1, .1, .1, 1})

		// Draw walls
		lwall_pos := b2d.Body_GetPosition(g_b2d_state.lwall)
		r2im.draw_sprite(lwall_pos * WORLD_TO_PIXEL, 0, {1*WORLD_TO_PIXEL, 100*WORLD_TO_PIXEL}, core.path_make_engine_textures_relative("white.png"), {.1, .1, .1, 1})
		rwall_pos := b2d.Body_GetPosition(g_b2d_state.rwall)
		r2im.draw_sprite(rwall_pos * WORLD_TO_PIXEL, 0, {1*WORLD_TO_PIXEL, 100*WORLD_TO_PIXEL}, core.path_make_engine_textures_relative("white.png"), {.1, .1, .1, 1})

		// Draw player
		player_pos := b2d.Body_GetPosition(g_b2d_state.player)
		player_rot := b2d.Body_GetRotation(g_b2d_state.player)
		player_angle := math.to_degrees(b2d.Rot_GetAngle(player_rot))
		player_redness := 1.0 - f32(g_game_state.player_lives) / PLAYER_MAX_LIVES
		player_color := linalg.lerp(Vec4{1, 1, 1, 1}, Vec4{1, 0, 0, 1}, player_redness)
		r2im.draw_sprite(player_pos * WORLD_TO_PIXEL, player_angle, {PLAYER_PIXEL_SIZE, PLAYER_PIXEL_SIZE}, core.path_make_engine_textures_relative("test.png"), player_color)

		// Draw boxes
		for box in g_b2d_state.boxes {
			box_pos := b2d.Body_GetPosition(box)
			box_rot := b2d.Body_GetRotation(box)
			box_angle := math.to_degrees(b2d.Rot_GetAngle(box_rot))
			r2im.draw_sprite(box_pos * WORLD_TO_PIXEL, box_angle, BOX_SIZE * WORLD_TO_PIXEL, core.path_make_engine_textures_relative("white.png"), {.3, .3, .3, 1})
			if (box_pos.y - BOX_SIZE.y/2) > (ground_pos.y + 0.5) {
				hint_alpha := 1.0 - ((box_pos.y - BOX_SIZE.y/2) - (ground_pos.y + 0.5)) / 25
				r2im.draw_sprite(Vec2{box_pos.x, ground_pos.y + 0.5}*WORLD_TO_PIXEL, 0, {BOX_SIZE.x, 0.2}*WORLD_TO_PIXEL, core.path_make_engine_textures_relative("white.png"), {1, 0, 0, hint_alpha})
			}
		}

		// Draw falling hearts
		for heart in g_b2d_state.hearts {
			heart_pos := b2d.Body_GetPosition(heart)
			heart_rot := b2d.Body_GetRotation(heart)
			heart_angle := math.to_degrees(b2d.Rot_GetAngle(heart_rot))
			r2im.draw_sprite(heart_pos * WORLD_TO_PIXEL, heart_angle, PLAYER_SIZE * WORLD_TO_PIXEL, "res/textures/hp.png")
		}

		// Draw debug no-spawn zone
		// if g_game_state.debug_no_spawn_zone.min != 0 && g_game_state.debug_no_spawn_zone.max != 0 {
		// 	zone_center := (g_game_state.debug_no_spawn_zone.max + g_game_state.debug_no_spawn_zone.min) / 2
		// 	zone_size := g_game_state.debug_no_spawn_zone.max - g_game_state.debug_no_spawn_zone.min
		// 	r2im.draw_sprite(Vec2{zone_center, ground_pos.y + 0.5}*WORLD_TO_PIXEL, 0, {zone_size - BOX_SIZE.x, 0.2}*WORLD_TO_PIXEL, core.path_make_engine_textures_relative("white.png"), {0, 1, 0, 0.4})
		// }

		// Draw lives
		for i in 0..<g_game_state.player_lives {
			r2im.draw_sprite({-600 + f32(i)*30, 300}, 0, {20, 20}, "res/textures/hp.png")
		}
	
		r2im.end_frame()
	}
}
