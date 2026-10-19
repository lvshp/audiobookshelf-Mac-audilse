#include <vlc/vlc.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <inttypes.h>
#include <pthread.h>
#include <unistd.h>
#include <sys/sysctl.h>
static FILE *output;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static uint64_t frames, nonzero;
static int bad;
static void pre(void *context, uint8_t **buffer, size_t size) { *buffer = malloc(size); }
static void post(void *context, uint8_t *buffer, unsigned channels, unsigned rate,
                 unsigned count, unsigned bits, size_t size, int64_t pts) {
    pthread_mutex_lock(&lock);
    if (!buffer || channels != 2 || rate != 48000 || bits != 16 || size < (size_t)count * 4) bad = 1;
    else {
        frames += count;
        const int16_t *samples = (const int16_t *)buffer;
        for (size_t i = 0; i < (size_t)count * 2; i++) if (samples[i]) nonzero++;
        if (fwrite(buffer, 4, count, output) != count) bad = 1;
    }
    pthread_mutex_unlock(&lock);
    free(buffer);
}
int main(int argc, char **argv) {
    if (argc != 3) return 2;
    output = fopen(argv[2], "wb"); if (!output) return 3;
    char sout[1024];
    snprintf(sout, sizeof(sout), "--sout=#transcode{acodec=s16l,channels=2,samplerate=48000}:smem{audio-prerender-callback=%"PRIdPTR",audio-postrender-callback=%"PRIdPTR",audio-data=0,no-time-sync}", (intptr_t)pre, (intptr_t)post);
    const char *options[] = {"--no-video", "--no-play-and-pause", "--no-sout-video", "--no-sout-spu", sout};
    libvlc_instance_t *instance = libvlc_new(5, options); if (!instance) return 4;
    printf("VERSION %s\nCHANGESET %s\n", libvlc_get_version(), libvlc_get_changeset());
    int translated = 0; size_t length = sizeof(translated);
    if (sysctlbyname("sysctl.proc_translated", &translated, &length, NULL, 0) != 0) translated = 0;
    printf("TRANSLATED %d\n", translated);
    libvlc_media_player_t *player = libvlc_media_player_new(instance);
    libvlc_media_t *media = libvlc_media_new_path(instance, argv[1]);
    if (!player || !media) return 5;
    char option[1024]; snprintf(option, sizeof(option), ":%s", sout + 2);
    libvlc_media_add_option(media, option);
    libvlc_media_player_set_media(player, media); libvlc_media_release(media);
    if (libvlc_media_player_play(player) != 0) return 6;
    int state = 0;
    for (int n = 0; n < 1500; n++) { state = libvlc_media_player_get_state(player); if (state == 6 || state == 7) break; usleep(20000); }
    libvlc_media_player_stop(player); libvlc_media_player_release(player); libvlc_release(instance); fclose(output);
    printf("RESULT state=%d frames=%"PRIu64" nonzero=%"PRIu64" bad=%d\n", state, frames, nonzero, bad);
    return state == 6 && !bad ? 0 : 7;
}
