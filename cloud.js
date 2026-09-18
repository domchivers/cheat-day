/* Accounts and sync, via Firebase (email + password sign-in, one Firestore document per user).
 * Only active when firebase-config.js holds a real config; otherwise the app stays device-only.
 * Exposes window.cloud to app.js and fires a "cloud-ready" event once it's decided either way. */
import { initializeApp } from "https://www.gstatic.com/firebasejs/11.0.1/firebase-app.js";
import {
  getAuth, onAuthStateChanged, signInWithEmailAndPassword, createUserWithEmailAndPassword,
  signOut, sendPasswordResetEmail
} from "https://www.gstatic.com/firebasejs/11.0.1/firebase-auth.js";
import { getFirestore, doc, setDoc, onSnapshot } from "https://www.gstatic.com/firebasejs/11.0.1/firebase-firestore.js";

const cfg = window.FIREBASE_CONFIG;
if (!cfg || !cfg.apiKey) {
  window.cloud = null;
} else {
  const app = initializeApp(cfg);
  const auth = getAuth(app);
  const db = getFirestore(app);
  let user = null, unsubscribe = null;
  const authListeners = [], dataListeners = [];

  window.cloud = {
    get user() { return user; },
    onAuth(cb) { authListeners.push(cb); if (auth.currentUser !== undefined) cb(user); },
    onData(cb) { dataListeners.push(cb); },
    signIn: (email, password) => signInWithEmailAndPassword(auth, email, password),
    signUp: (email, password) => createUserWithEmailAndPassword(auth, email, password),
    signOut: () => signOut(auth),
    resetPassword: (email) => sendPasswordResetEmail(auth, email),
    push: (data) => user ? setDoc(doc(db, "users", user.uid), { ...data, updatedAt: Date.now() }) : Promise.resolve(),
    /** Turn a Firebase error into something a person can read. */
    explain(err) {
      const code = (err && err.code) || "";
      if (code.includes("invalid-credential") || code.includes("wrong-password") || code.includes("user-not-found")) return "Email or password isn't right.";
      if (code.includes("email-already-in-use")) return "There's already an account with that email. Try signing in.";
      if (code.includes("weak-password")) return "Password needs at least 6 characters.";
      if (code.includes("invalid-email")) return "That email address doesn't look right.";
      if (code.includes("network")) return "No connection. Try again when you're online.";
      if (code.includes("api-key-not-valid") || code.includes("configuration-not-found")) return "Accounts aren't set up yet. Check firebase-config.js and the Firebase console.";
      if (code.includes("too-many-requests")) return "Too many tries. Wait a minute and try again.";
      return (err && err.message) || "Something went wrong.";
    }
  };

  onAuthStateChanged(auth, (u) => {
    user = u;
    if (unsubscribe) { unsubscribe(); unsubscribe = null; }
    if (u) {
      // The first snapshot is the load-on-sign-in; later ones are changes from other devices.
      unsubscribe = onSnapshot(doc(db, "users", u.uid), (snap) => {
        if (snap.metadata.hasPendingWrites) return;   // our own write echoing back
        dataListeners.forEach((cb) => cb(snap.exists() ? snap.data() : null));
      }, (err) => console.warn("sync", err));
    }
    authListeners.forEach((cb) => cb(u));
  });
}
window.dispatchEvent(new Event("cloud-ready"));
