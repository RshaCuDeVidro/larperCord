//! Trazer para a frente, no Wayland, a janela que já está aberta (atrás de outra
//! ou minimizada), com a ficha de ativação que o painel mandou junto do clique no
//! ícone (ProvideXdgActivationToken, ver sni.zig). O SDL só usa essa ficha ao
//! mostrar uma janela escondida; com a janela aberta, o SDL_RaiseWindow pede uma
//! ficha própria com o foco no painel, e o KWin recusa (marca a janela como
//! pedindo atenção) e o Mutter mostra um aviso de "está pronto". Aqui a ficha do
//! painel vai direto ao xdg_activation_v1.activate.
//!
//! A libwayland-client é aberta na hora (o SDL também a abre assim), e o registro
//! corre numa fila de eventos própria: nada do que o SDL espera na fila dele é
//! tocado. Sem Wayland, sem a biblioteca (anterior à 1.20) ou sem o protocolo no
//! compositor, `activate` devolve false e quem chama segue com o SDL_RaiseWindow.
const std = @import("std");
const c = @import("c");

const Proxy = opaque {};
const Queue = opaque {};

const Message = extern struct { name: [*:0]const u8, signature: [*:0]const u8, types: [*]const ?*const Interface };
const Interface = extern struct {
    name: [*:0]const u8,
    version: c_int,
    method_count: c_int,
    methods: ?[*]const Message,
    event_count: c_int,
    events: ?[*]const Message,
};
/// union wl_argument: um valor por argumento do pedido.
const Arg = extern union { u: u32, s: ?[*:0]const u8, o: ?*anyopaque };

const Fns = struct {
    wl_display_create_queue: *const fn (*Proxy) callconv(.c) ?*Queue,
    wl_display_roundtrip_queue: *const fn (*Proxy, *Queue) callconv(.c) c_int,
    wl_display_flush: *const fn (*Proxy) callconv(.c) c_int,
    wl_event_queue_destroy: *const fn (*Queue) callconv(.c) void,
    wl_proxy_create_wrapper: *const fn (*Proxy) callconv(.c) ?*Proxy,
    wl_proxy_wrapper_destroy: *const fn (*Proxy) callconv(.c) void,
    wl_proxy_set_queue: *const fn (*Proxy, ?*Queue) callconv(.c) void,
    wl_proxy_get_version: *const fn (*Proxy) callconv(.c) u32,
    wl_proxy_add_listener: *const fn (*Proxy, *const anyopaque, ?*anyopaque) callconv(.c) c_int,
    wl_proxy_destroy: *const fn (*Proxy) callconv(.c) void,
    wl_proxy_marshal_array_flags: *const fn (*Proxy, u32, ?*const Interface, u32, u32, [*]Arg) callconv(.c) ?*Proxy,
};
var w: Fns = undefined;
var registry_iface: *const Interface = undefined;

// O protocolo xdg-activation-v1, como o wayland-scanner geraria. A ficha
// (xdg_activation_token_v1) nunca é criada aqui, mas o pedido que a cria precisa
// do tipo dela.
var nulls = [_]?*const Interface{ null, null };
var token_types = [_]?*const Interface{&token_iface};
/// [1] = wl_surface, preenchido em `load`.
var activate_types = [_]?*const Interface{ null, null };
const token_requests = [_]Message{
    .{ .name = "set_serial", .signature = "uo", .types = &nulls },
    .{ .name = "set_app_id", .signature = "s", .types = &nulls },
    .{ .name = "set_surface", .signature = "o", .types = &nulls },
    .{ .name = "commit", .signature = "", .types = &nulls },
    .{ .name = "destroy", .signature = "", .types = &nulls },
};
const token_events = [_]Message{.{ .name = "done", .signature = "s", .types = &nulls }};
const token_iface: Interface = .{ .name = "xdg_activation_token_v1", .version = 1, .method_count = token_requests.len, .methods = &token_requests, .event_count = token_events.len, .events = &token_events };
const activation_requests = [_]Message{
    .{ .name = "destroy", .signature = "", .types = &nulls },
    .{ .name = "get_activation_token", .signature = "n", .types = &token_types },
    .{ .name = "activate", .signature = "so", .types = &activate_types },
};
const activation_iface: Interface = .{ .name = "xdg_activation_v1", .version = 1, .method_count = activation_requests.len, .methods = &activation_requests, .event_count = 0, .events = null };
const op_activate = 2;
const op_get_registry = 1;
const op_bind = 0;

var tried = false;
/// O xdg_activation_v1 do compositor, na nossa fila (o objeto vale até o fim).
var activation: ?*Proxy = null;

fn load() bool {
    const lib = c.SDL_LoadObject("libwayland-client.so.0") orelse return false;
    inline for (@typeInfo(Fns).@"struct".field_names) |fname| {
        const sym = c.SDL_LoadFunction(lib, fname.ptr) orelse return false;
        @field(w, fname) = @ptrCast(sym);
    }
    // Os dois são dados exportados pela biblioteca: o endereço é o da interface.
    registry_iface = @ptrCast(@alignCast(c.SDL_LoadFunction(lib, "wl_registry_interface") orelse return false));
    activate_types[1] = @ptrCast(@alignCast(c.SDL_LoadFunction(lib, "wl_surface_interface") orelse return false));
    return true;
}

const Found = struct { name: u32 = 0 };

fn onGlobal(data: ?*anyopaque, _: *Proxy, name: u32, iface: [*:0]const u8, _: u32) callconv(.c) void {
    const found: *Found = @ptrCast(@alignCast(data.?));
    if (std.mem.eql(u8, std.mem.span(iface), "xdg_activation_v1")) found.name = name;
}

fn onGlobalRemove(_: ?*anyopaque, _: *Proxy, _: u32) callconv(.c) void {}

const registry_listener = extern struct {
    global: *const fn (?*anyopaque, *Proxy, u32, [*:0]const u8, u32) callconv(.c) void = &onGlobal,
    global_remove: *const fn (?*anyopaque, *Proxy, u32) callconv(.c) void = &onGlobalRemove,
}{};

/// Procura o xdg_activation_v1 uma vez, numa fila só nossa.
fn bind(display: *Proxy) ?*Proxy {
    if (tried) return activation;
    tried = true;
    if (!load()) return null;
    const queue = w.wl_display_create_queue(display) orelse return null;
    const wrapper = w.wl_proxy_create_wrapper(display) orelse {
        w.wl_event_queue_destroy(queue);
        return null;
    };
    w.wl_proxy_set_queue(wrapper, queue);
    var reg_args = [_]Arg{.{ .o = null }};
    const registry = w.wl_proxy_marshal_array_flags(wrapper, op_get_registry, registry_iface, w.wl_proxy_get_version(wrapper), 0, &reg_args);
    w.wl_proxy_wrapper_destroy(wrapper);
    const reg = registry orelse {
        w.wl_event_queue_destroy(queue);
        return null;
    };
    var found: Found = .{};
    _ = w.wl_proxy_add_listener(reg, &registry_listener, &found);
    if (w.wl_display_roundtrip_queue(display, queue) >= 0 and found.name != 0) {
        var bind_args = [_]Arg{ .{ .u = found.name }, .{ .s = activation_iface.name }, .{ .u = 1 }, .{ .o = null } };
        activation = w.wl_proxy_marshal_array_flags(reg, op_bind, &activation_iface, 1, 0, &bind_args);
    }
    w.wl_proxy_destroy(reg);
    // Sem o objeto, a fila não serve para nada; com ele, fica junto dele.
    if (activation == null) w.wl_event_queue_destroy(queue);
    return activation;
}

/// Entrega a ficha do painel ao compositor para ativar a janela. false = não é
/// Wayland ou não deu (quem chama segue com o SDL_RaiseWindow).
pub fn activate(window: *c.SDL_Window, token: [:0]const u8) bool {
    if (comptime @import("builtin").os.tag != .linux) return false;
    const driver = c.SDL_GetCurrentVideoDriver() orelse return false;
    if (!std.mem.eql(u8, std.mem.span(driver), "wayland")) return false;
    const display: *Proxy = @ptrCast(c.SDL_GetPointerProperty(c.SDL_GetGlobalProperties(), c.SDL_PROP_GLOBAL_VIDEO_WAYLAND_WL_DISPLAY_POINTER, null) orelse return false);
    const surface = c.SDL_GetPointerProperty(c.SDL_GetWindowProperties(window), c.SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER, null) orelse return false;
    const act = bind(display) orelse return false;
    var args = [_]Arg{ .{ .s = token.ptr }, .{ .o = surface } };
    _ = w.wl_proxy_marshal_array_flags(act, op_activate, null, w.wl_proxy_get_version(act), 0, &args);
    _ = w.wl_display_flush(display);
    return true;
}
