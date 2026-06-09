#include <Processing.NDI.Lib.h>
#include <SDL2/SDL.h>

#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static volatile bool running = true;

static void stop(int sig) {
  (void)sig;
  running = false;
}

static const NDIlib_source_t *find_source(NDIlib_find_instance_t finder,
                                          const char *name,
                                          uint32_t *source_count) {
  const NDIlib_source_t *sources = NULL;

  for (int i = 0; i < 30 && running; i++) {
    NDIlib_find_wait_for_sources(finder, 1000);
    sources = NDIlib_find_get_current_sources(finder, source_count);

    if (!name || !name[0]) {
      if (*source_count > 0) return &sources[0];
      continue;
    }

    for (uint32_t j = 0; j < *source_count; j++) {
      if (sources[j].p_ndi_name && strcmp(sources[j].p_ndi_name, name) == 0) {
        return &sources[j];
      }
    }
  }

  return NULL;
}

int main(int argc, char **argv) {
  const char *source_name = argc > 1 ? argv[1] : "";

  signal(SIGINT, stop);
  signal(SIGTERM, stop);

  if (!NDIlib_initialize()) {
    fprintf(stderr, "NDI runtime failed to initialize\n");
    return 1;
  }

  NDIlib_find_instance_t finder = NDIlib_find_create_v2(NULL);
  if (!finder) {
    fprintf(stderr, "NDI finder failed to start\n");
    NDIlib_destroy();
    return 1;
  }

  uint32_t source_count = 0;
  const NDIlib_source_t *source = find_source(finder, source_name, &source_count);
  if (!source) {
    fprintf(stderr, "NDI source not found: %s\n", source_name && source_name[0] ? source_name : "(first available)");
    NDIlib_find_destroy(finder);
    NDIlib_destroy();
    return 2;
  }

  fprintf(stdout, "Connecting to NDI source: %s\n", source->p_ndi_name);
  fflush(stdout);

  NDIlib_recv_create_v3_t recv_desc;
  memset(&recv_desc, 0, sizeof(recv_desc));
  recv_desc.source_to_connect_to = *source;
  recv_desc.color_format = NDIlib_recv_color_format_BGRX_BGRA;
  recv_desc.bandwidth = NDIlib_recv_bandwidth_highest;

  NDIlib_recv_instance_t recv = NDIlib_recv_create_v3(&recv_desc);
  NDIlib_find_destroy(finder);

  if (!recv) {
    fprintf(stderr, "NDI receiver failed to start\n");
    NDIlib_destroy();
    return 1;
  }

  if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_EVENTS) != 0) {
    fprintf(stderr, "SDL failed to initialize: %s\n", SDL_GetError());
    NDIlib_recv_destroy(recv);
    NDIlib_destroy();
    return 1;
  }

  SDL_Window *window = SDL_CreateWindow("SignageOS NDI",
    SDL_WINDOWPOS_UNDEFINED, SDL_WINDOWPOS_UNDEFINED,
    1280, 720, SDL_WINDOW_SHOWN | SDL_WINDOW_FULLSCREEN_DESKTOP);
  if (!window) {
    fprintf(stderr, "SDL window failed: %s\n", SDL_GetError());
    SDL_Quit();
    NDIlib_recv_destroy(recv);
    NDIlib_destroy();
    return 1;
  }

  SDL_Renderer *renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);
  if (!renderer) {
    renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_SOFTWARE);
  }
  if (!renderer) {
    fprintf(stderr, "SDL renderer failed: %s\n", SDL_GetError());
    SDL_DestroyWindow(window);
    SDL_Quit();
    NDIlib_recv_destroy(recv);
    NDIlib_destroy();
    return 1;
  }

  SDL_Texture *texture = NULL;
  int tex_w = 0;
  int tex_h = 0;

  while (running) {
    SDL_Event event;
    while (SDL_PollEvent(&event)) {
      if (event.type == SDL_QUIT) running = false;
      if (event.type == SDL_KEYDOWN && event.key.keysym.sym == SDLK_ESCAPE) running = false;
    }

    NDIlib_video_frame_v2_t video_frame;
    NDIlib_audio_frame_v2_t audio_frame;
    NDIlib_metadata_frame_t metadata_frame;

    switch (NDIlib_recv_capture_v2(recv, &video_frame, &audio_frame, &metadata_frame, 1000)) {
      case NDIlib_frame_type_video:
        if (!texture || tex_w != video_frame.xres || tex_h != video_frame.yres) {
          if (texture) SDL_DestroyTexture(texture);
          tex_w = video_frame.xres;
          tex_h = video_frame.yres;
          texture = SDL_CreateTexture(renderer, SDL_PIXELFORMAT_BGRA32,
                                      SDL_TEXTUREACCESS_STREAMING, tex_w, tex_h);
        }

        if (texture) {
          SDL_UpdateTexture(texture, NULL, video_frame.p_data, video_frame.line_stride_in_bytes);
          SDL_RenderClear(renderer);
          SDL_RenderCopy(renderer, texture, NULL, NULL);
          SDL_RenderPresent(renderer);
        }
        NDIlib_recv_free_video_v2(recv, &video_frame);
        break;

      case NDIlib_frame_type_audio:
        NDIlib_recv_free_audio_v2(recv, &audio_frame);
        break;

      case NDIlib_frame_type_metadata:
        NDIlib_recv_free_metadata(recv, &metadata_frame);
        break;

      default:
        break;
    }
  }

  if (texture) SDL_DestroyTexture(texture);
  SDL_DestroyRenderer(renderer);
  SDL_DestroyWindow(window);
  SDL_Quit();
  NDIlib_recv_destroy(recv);
  NDIlib_destroy();

  return 0;
}
