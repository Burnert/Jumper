package jumper

import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
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
	world_def.gravity = Vec2{0, -10}
	g_b2d_state.world = b2d.CreateWorld(world_def)
	defer b2d.DestroyWorld(g_b2d_state.world)

	// Create ground as a static body
	ground_def := b2d.DefaultBodyDef()
	ground_def.position = Vec2{0, -7}
	g_b2d_state.ground = b2d.CreateBody(g_b2d_state.world, ground_def)
	defer b2d.DestroyBody(g_b2d_state.ground)

	// Set ground polygon shape
	ground_shape_def := b2d.DefaultShapeDef()
	ground_shape_def.restitution = 0.3
	ground_box := b2d.MakeBox(50, 0.5)
	ground_shape_id := b2d.CreatePolygonShape(g_b2d_state.ground, ground_shape_def, ground_box)

	// Create player as a Box2d dynamic body
	player_def := b2d.DefaultBodyDef()
	player_def.type = .dynamicBody
	player_def.position = Vec2{0, 0}
	player_def.angularVelocity = 0.5 * math.TAU
	g_b2d_state.player = b2d.CreateBody(g_b2d_state.world, player_def)
	defer b2d.DestroyBody(g_b2d_state.player)

	// Set player polygon shape
	player_shape_def := b2d.DefaultShapeDef()
	player_shape_def.density = 1
	player_shape_def.friction = 0.3
	player_polygon := b2d.MakeBox(0.5, 0.5)
	player_shape_id := b2d.CreatePolygonShape(g_b2d_state.player, player_shape_def, player_polygon)

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

Box2d_State :: struct {
	world: b2d.WorldId,
	ground: b2d.BodyId,
	player: b2d.BodyId,
}
g_b2d_state: Box2d_State

update :: proc(dt: f64) {
	b2d.World_Step(g_b2d_state.world, cast(f32) dt, 4)
}

draw :: proc() {
	if r2im.begin_frame() {
		player_pos := b2d.Body_GetPosition(g_b2d_state.player)
		player_rot := b2d.Body_GetRotation(g_b2d_state.player)
		player_angle := math.to_degrees(b2d.Rot_GetAngle(player_rot))
		ground_pos := b2d.Body_GetPosition(g_b2d_state.ground)
		r2im.draw_sprite(player_pos * WORLD_TO_PIXEL, player_angle, {1*WORLD_TO_PIXEL, 1*WORLD_TO_PIXEL}, core.path_make_engine_textures_relative("white.png"))
		r2im.draw_sprite(ground_pos * WORLD_TO_PIXEL, 0, {100*WORLD_TO_PIXEL, 1*WORLD_TO_PIXEL}, core.path_make_engine_textures_relative("white.png"), {.1, .1, .1, 1})
		r2im.end_frame()
	}
}
