package tr.randward.btboot;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.util.Log;

/*
 * At boot, ask init to start the root "runin_test_restart" service; runin.sh then
 * evals /sdcard/runin_config, which runs /data/local/tmp/rtkbt/rtkbt-up.sh.
 * Works only because SELinux is permissive on this box.
 */
public class Boot extends BroadcastReceiver {
    static void trigger() {
        try {
            Runtime.getRuntime().exec(new String[] {
                    "/system/bin/setprop", "debug.runin.restart", "1" }).waitFor();
            Log.i("btboot", "requested runin_test_restart");
        } catch (Exception e) {
            Log.e("btboot", "setprop failed", e);
        }
    }

    @Override
    public void onReceive(Context context, Intent intent) {
        final PendingResult pr = goAsync();
        new Thread(() -> { trigger(); pr.finish(); }).start();
    }
}
