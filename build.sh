#!/bin/zsh
LAMP_MAC_USAGE='  <key>NSMicrophoneUsageDescription</key><string>Disk Map listens to your microphone.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Disk Map turns your speech into text.</string>
  <key>NSCameraUsageDescription</key><string>Disk Map uses your camera.</string>
  <key>NSPhotoLibraryUsageDescription</key><string>Disk Map uses your photos.</string>
  <key>NSPhotoLibraryAddUsageDescription</key><string>Disk Map saves pictures to your photos.</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>Disk Map reads and adds calendar events.</string>
  <key>NSRemindersFullAccessUsageDescription</key><string>Disk Map reads and adds reminders.</string>
  <key>NSContactsUsageDescription</key><string>Disk Map looks up people in your contacts.</string>
  <key>NSBluetoothAlwaysUsageDescription</key><string>Disk Map connects to Bluetooth devices.</string>
  <key>NSAppleEventsUsageDescription</key><string>Disk Map reads your email and drafts replies through Mail.</string>
  <key>NSLocalNetworkUsageDescription</key><string>Disk Map looks for printers and other devices on your network.</string>
  <key>NSLocationUsageDescription</key><string>Disk Map uses your location.</string>
  <key>NSLocationWhenInUseUsageDescription</key><string>Disk Map uses your location.</string>
  <key>NSAppleMusicUsageDescription</key><string>Disk Map plays music from your library.</string>'
LAMP_APP_NAME='Disk Map'
# Builds build/DiskMap.app. Run after every change.
set -euo pipefail
cd "$(dirname "$0")"
# dyld ignores DYLD_INSERT_LIBRARIES and the like for a binary with a __RESTRICT segment. The agent's shell
# can start the installed app, and Lamp answers its secrets calls only to the app itself (PeerProcess), so
# nothing may ride into it this way. Loading from inside the app (LiveReload's dlopen) is unaffected.
mkdir -p .build
: > .build/restrict
RESTRICT=(-Xlinker -sectcreate -Xlinker __RESTRICT -Xlinker __restrict -Xlinker "$PWD/.build/restrict")
FLAGS=(-c release -Xswiftc -g "${RESTRICT[@]}")
# A live build (Lamp's changing apps while they're open): debug, linked so a change can be put into the running
# app (LampLive), from a copy of the sources in .lamp/live with each view's body wrapped so its type stays the
# same from one change to the next. A file is copied only when it differs, so builds stay incremental.
if [[ "${LAMP_LIVE:-}" == 1 ]]; then
  LIVE=.lamp/live
  mkdir -p "$LIVE/Sources"
  cat > "$LIVE/live.pl" <<'LAMPLIVE'
use strict; use warnings; use Digest::MD5 qw(md5_hex);
local $/;
my $modifier = qr/(?:func|var|let|subscript|override|class|final|open|public|internal|private|fileprivate|package|static|dynamic|required|convenience|nonisolated|lazy|weak|unowned|optional|indirect|init|deinit)\b/;
if (($ARGV[0] // '') eq 'scan') {
    shift @ARGV;
    # Lamp's own files (`-own=LampSupport.swift,…`) are scanned for names like the rest, but what they do with
    # raw memory is their own business, never a reason to keep the app's structs from their spares.
    my %own = map { $_ => 1 } split /,/, (($ARGV[0] // '') =~ /^-own=(.*)/ ? do { shift @ARGV; $1 } : '');
    # Lamp's list of the structs the app reads as bytes (`LiveSlots.noteByteStructs`), when it has made one.
    my $bytes = ($ARGV[0] // '') =~ /^-bytes=(.*)/ ? do { shift @ARGV; $1 } : '';
    my (%names, %alias, %nospare, %equatable, %reflects, %bodies, @appTexts, $raw, $mirrors);
    for my $file (@ARGV) {
        open(my $in, '<', $file) or next; my $s = <$in>; close($in);
        # A struct read as bytes anywhere (MemoryLayout, a buffer handed to Metal, an array's or a value's own bytes)
        # must stay the size it's written with, and the one read may be declared in another file: so no struct gets
        # a spare in such an app. Which of `withUnsafeBytes`'s receivers holds structs isn't in the text, so any counts.
        push @appTexts, $s if !$own{(split m#/#, $file)[-1]};
        $raw = 1 if !$own{(split m#/#, $file)[-1]} && $s =~ /MemoryLayout|withUnsafe|unsafeBitCast|makeBuffer|withContiguous(?:Mutable)?StorageIfAvailable|Unsafe(?:Mutable)?(?:Raw)?(?:Buffer)?Pointer|LowLevelMesh|MTLBuffer|\@frozen/;
        $s =~ s#/\*[\s\S]*?\*/# #g; $s =~ s#//[^\n]*##g;
        # Each struct's body, for which structs one read as bytes holds (below).
        while ($s =~ /\bstruct\s+(\w+)[^{;]*\{/g) {
            my ($name, $at, $depth) = ($1, pos($s), 1); my $i = $at;
            while ($i < length($s) && $depth) { my $c = substr($s, $i++, 1); $depth++ if $c eq '{'; $depth-- if $c eq '}' }
            $bodies{$name} .= substr($s, $at, $i - $at);
        }
        # A struct made an OptionSet or RawRepresentable in an extension: its memberwise initializer is the
        # protocol's `init(rawValue:)`, which a spare's parameter would unfit. One made BitwiseCopyable can hold
        # nothing a spare is.
        while ($s =~ /\bextension\s+([\w.]+)\s*:[^{]*\b(?:OptionSet|RawRepresentable|BitwiseCopyable)\b/g) { $nospare{(split /\./, $1)[-1]} = 1 }
        # A view made Equatable or Hashable in an extension: its state box isn't either, and the synthesized
        # conformance would fail as it does for one declared so (`spares` reads only the declaration's header).
        while ($s =~ /\bextension\s+([\w.]+)\s*:[^{]*\b(?:Equatable|Hashable)\b/g) { $equatable{(split /\./, $1)[-1]} = 1 }
        # A struct with a mirror of its own keeps it (`spares` gives one to the rest): made CustomReflectable in an
        # extension, or any `customMirror` the app's code writes, which a second would clash with.
        while ($s =~ /\bextension\s+([\w.]+)\s*:[^{]*\bCustomReflectable\b/g) { $reflects{(split /\./, $1)[-1]} = 1 }
        $mirrors = 1 if !$own{(split m#/#, $file)[-1]} && $s =~ /\bcustomMirror\b/;
        # A class under a class of the same simple name (`B.Item: A.Item`): spare places are named by the simple
        # name, so the subclass's would override the superclass's stored ones. Neither gets any.
        while ($s =~ /\bclass\s+(?!$modifier)(\w+)(?:<[^>]*>)?\s*:\s*([\w.]+)/g) { my ($n, $up) = ($1, (split /\./, $2)[-1]); $nospare{$n} = 1 if $n eq $up }
        while ($s =~ /\btypealias\s+(\w+)(?:<[^>]*>)?\s*=\s*([\w.]+)/g) { $alias{$1} = $2 }
        while ($s =~ /\bclass\s+\w+(?:<[^>]*>)?\s*:\s*([\w.]+)/g) { $names{$1} = 1 }
        while ($s =~ /<[^<>]*>/g) { my $g = $&; while ($g =~ /:\s*([\w.]+)/g) { $names{$1} = 1 } }
        while ($s =~ /\bwhere\b(?!\s*:)([^{]*)/g) { my $w = $1; while ($w =~ /:\s*([\w.]+)/g) { $names{$1} = 1 } }
    }
    for my $name (keys %names) { my $n = $name; for (1 .. 4) { last unless exists $alias{(split /\./, $n)[-1]}; $n = $alias{(split /\./, $n)[-1]}; $names{$n} = 1 } }
    # With Lamp's list for these very files, only the structs read as bytes, and those they hold, go without a spare;
    # without it (none made, a stale one, or `*`), none get one in such an app.
    my $byteList;
    if ($raw && $bytes ne '' && open(my $list, '<', $bytes)) {
        my @read = split /\n/, <$list>; close($list);
        if (@read && $read[0] eq 'md5 ' . md5_hex(join("\n", sort map { md5_hex($_) } @appTexts)) && !grep { $_ eq '*' } @read) {
            ($byteList, $raw) = (1, 0);
            my (@todo, %seen) = @read[1 .. $#read];
            while (defined(my $n = shift @todo)) {
                next if $seen{$n}++;
                $nospare{$n} = 1;
                my $body = $bodies{$n} // next;
                push @todo, grep { !$seen{$_} && $body =~ /\b\Q$_\E\b/ } keys %bodies;
            }
        }
    }
    # The names, then what the spares step is told: `-raw`, and `-nospare:Name` for each.
    print join(' ', sort(keys %names), ($raw ? '-raw' : ()), ($byteList ? '-bytes' : ()), ($mirrors ? '-nomirror' : ()), (map { "-nospare:$_" } sort keys %nospare),
        (map { "-equatable:$_" } sort keys %equatable), map { "-reflects:$_" } sort keys %reflects), "\n";
    exit 0;
}
my ($count, $subclassed, $flags, @files) = @ARGV;
my %subclassed = map { (split /\./)[-1] => 1 } grep { !/^-/ } split ' ', $subclassed;
my $rawAll = $subclassed =~ /(?:^|\s)-raw(?:\s|$)/;
my $bytesKnown = $subclassed =~ /(?:^|\s)-bytes(?:\s|$)/;
my %nospare = map { substr($_, 9) => 1 } grep { /^-nospare:/ } split ' ', $subclassed;
my %equatable = map { substr($_, 11) => 1 } grep { /^-equatable:/ } split ' ', $subclassed;
my %reflects = map { substr($_, 10) => 1 } grep { /^-reflects:/ } split ' ', $subclassed;
my $noMirror = $subclassed =~ /(?:^|\s)-nomirror(?:\s|$)/;
# A struct given a spare is made CustomReflectable in its own header, so its description leaves the spare out
# (`LampSpare.mirror`): after its inheritance list, before a `where`, or as the list when it has none.
sub conform {
    my ($whole, $name) = @_;
    return undef unless $whole =~ /^([\s\S]*?\bstruct\s+\Q$name\E)(?<g><(?:[^<>]++|(?&g))*>)?([^{]*?)(\s*)\{\z/;
    my ($head, $generics, $rest, $space) = ($1, $2 // '', $3, $4);
    if ($rest =~ /^\s*:/) {
        $rest =~ s/(\s)where\b/, CustomReflectable$1where/ or $rest =~ s/(\s*)\z/, CustomReflectable$1/;
    } else {
        $rest = ": CustomReflectable" . $rest;
    }
    return "$head$generics$rest$space\{";
}
my $wantSpares = $flags =~ /s/; my $wantFinal = $flags =~ /f/;
# The stretches of a file no rewrite may touch, worked out again after each rewrite moves them.
my @skip;
sub spans {
    my $s = shift; my @found;
    while ($s =~ /((#+)"""(?:\\\2[\s\S]|\\(?!\2)|[^\\])*?"""\2|"""(?:\\[\s\S]|[^\\])*?"""|(#+)"(?:\\\3[^\n]|\\(?!\3)|[^"\\\n]|"(?!\3))*?"\3|"(?:[^"\\\n]|\\.)*"|(?<blk>\/\*(?:(?&blk)|(?!\*\/)[\s\S])*+(?:\*\/|\z))|\/\/[^\n]*)/g) { push @found, [$-[0], $+[0]] }
    return @found;
}
sub inside { my $p = shift; for my $span (@skip) { return 1 if $p >= $span->[0] && $p < $span->[1] } 0 }
sub spares {
    my ($i, $whole, $header, $kind, $name, $raw) = @_;
    # On a line of its own the places go under it, indented; after other text they go on the same line.
    my $pad = $i =~ /^[ \t]*$/ ? "\n$i    " : " ";
    if ($kind eq 'class') {
        return $whole if $nospare{$name} || $header =~ /\@Model\b|NSManagedObject|(?<!unchecked )\bSendable\b/;
        return $whole . join('', map { "${pad}var __lampSpare_${name}_$_: LampSpare? = nil;" } 0 .. $count - 1);
    }
    return $whole if $header =~ /\@propertyWrapper|\@frozen|\b(?:App|Scene|Commands|DynamicProperty|AppIntent|\w*Intent|AppEntity|\w*Query|TimelineProvider|TimelineEntry|Widget\w*)\b/;
    if ($header =~ /\bView\b/) {
        return $whole if $equatable{$name} || $header =~ /\b(?:Equatable|Hashable)\b/;
        # Its state's box, a place for new parameters, and its environment, which a new `@Environment(\.key)` reads.
        # The place isn't private: a private stored property with a starting value makes the initializer Swift
        # writes for the struct private on the Swift Apple ships now (6.4 leaves such a property out of it instead),
        # so a view made in another file wouldn't build. As a struct's, the place is one more argument with a
        # default, which a call never notices.
        return "${whole}${pad}\@State private var __lampState_${name} = LampStateBox();${pad}var __lampSpare_${name} = LampSpare(nil);${pad}\@Environment(\\.self) private var __lampEnv_${name};";
    }
    return $whole if $raw || $nospare{$name} || $header =~ /\b(?:OptionSet|RawRepresentable|BitwiseCopyable)\b/;
    my $mirrored = !$noMirror && !$reflects{$name} && $header !~ /\bCustomReflectable\b|~\s*(?:Copyable|Escapable)/ ? conform($whole, $name) : undef;
    return "${whole}${pad}var __lampSpare_${name} = LampSpare(nil);" unless defined $mirrored;
    return "${mirrored}${pad}var __lampSpare_${name} = LampSpare(nil);${pad}var customMirror: Mirror { LampSpare.mirror(of: self) };";
}
for my $file (@files) {
    open(my $in, '<', $file) or die "$file: $!"; my $s = <$in>; close($in);
    my $raw = $rawAll || !$bytesKnown && $s =~ /MemoryLayout|withUnsafe|unsafeBitCast|makeBuffer|withContiguous(?:Mutable)?StorageIfAvailable|Unsafe(?:Mutable)?(?:Raw)?(?:Buffer)?Pointer|LowLevelMesh|MTLBuffer|\@frozen/;
    @skip = spans($s);
    $s =~ s{var\s+body\s*:\s*some\s+(?:SwiftUI\.)?View\s*\{}~ inside($-[0]) ? $& : "var body: AnyView { _ = LampLive.generation; return AnyView(__lampBody) }\n    \@ViewBuilder var __lampBody: some View {" ~ge;
    @skip = spans($s);
    # What else SwiftUI keeps until something it reads changes: a modifier's and a style's body, and a layout's
    # placement. Each reads the generation too, so a change draws it again with the new code. Only a body that
    # returns `some View` (a view builder, where a statement before the views changes nothing) and a placement,
    # which returns nothing; never across another declaration (a protocol's requirement has no body, and the
    # next `{` may be a property's `{ get }`). Not a representable's update: run again on every change, it would
    # redo what it does each time (a web view reloading, a map going back to where it started).
    my $sig = qr/(?:(?!\b(?:func|var|let|init|subscript|struct|class|enum|protocol|extension|actor|case)\b)[^{}])*/;
    $s =~ s{\bfunc\s+(?:body\s*\(\s*content|makeBody\s*\(\s*configuration)$sig->\s*some\s+(?:SwiftUI\.)?View\s*\{|\bfunc\s+placeSubviews\s*\(\s*in$sig\)\s*\{}~ inside($-[0]) ? $& : "$&let _ = LampLive.touch(); " ~ge;
    # And the body of content that isn't a view (a toolbar's, a chart's, a map's, a tab's): built by a builder that
    # takes a statement first as a view builder does, and kept by SwiftUI the same way.
    @skip = spans($s);
    $s =~ s{\bvar\s+body\s*:\s*some\s+(?:SwiftUI\.|Charts\.|MapKit\.)?(?:ToolbarContent|CustomizableToolbarContent|ChartContent|MapContent|TabContent|AccessibilityRotorContent)\s*\{}~ inside($-[0]) ? $& : "$&let _ = LampLive.touch(); " ~ge;
    @skip = spans($s);
    # A layout's `sizeThatFits` too, which is asked again only when what it read changes. Its body runs inside a
    # closure that reads it first (`LampLive.touched`), which returns what the body returns, written as one
    # expression or with `return`; a statement before it would stop a one-expression body returning. The body's
    # end is found brace by brace outside strings and comments, from the last such method back.
    @skip = spans($s);
    my @layouts;
    while ($s =~ /\bfunc\s+sizeThatFits\s*\(\s*proposal$sig->\s*CGSize\s*\{/g) { push @layouts, pos($s) - 1 unless inside($-[0]) }
    for my $open (reverse @layouts) {
        my ($depth, $close) = (0, -1);
        for (my $i = $open; $i < length($s); $i++) {
            next if inside($i);
            my $c = substr($s, $i, 1);
            if ($c eq chr(123)) { $depth++ } elsif ($c eq chr(125)) { $depth--; if ($depth == 0) { $close = $i; last } }
        }
        next if $close < 0;
        substr($s, $close, 0) = " " . chr(125) . " ";
        substr($s, $open + 1, 0) = " LampLive.touched " . chr(123) . " ";
    }
    @skip = spans($s);
    my $main;
    $s =~ s{^([ \t]*(?:(?:\@\w+(?:\([^)]*\))?|public|internal|fileprivate|private|open|final)\s+)*)\@main((?:(?:\s|//[^\n]*|/\*[\s\S]*?\*/)+(?:\@\w+(?:\([^)]*\))?|public|internal|fileprivate|private|open|final))*(?:\s|//[^\n]*|/\*[\s\S]*?\*/)+(?:struct|class|enum|actor)\s+(\w+))}{ if (inside($-[0])) { $& } else { $main = $3; "$1$2" } }me;
    $s .= "\n\@main enum __LampEntry { \@MainActor static func main() { LampLive.watch(); $main.main() } }\n" if defined $main;
    if ($wantSpares) {
        @skip = spans($s);
        # At the start of a line, or after a brace or semicolon on one (a type declared inside another on one line).
        $s =~ s#(^[ \t]*|[{;][ \t]*)(((?:\@[\w.]+(?:\([^)\n]*\))?\s+)*(?:(?:public|private|fileprivate|internal|open|final|nonisolated|indirect)\s+)*)(class|struct)\s+(?!$modifier)(\w+)([^{;]*)\{)#inside($-[0] + length($1)) ? $& : $1 . spares($1, $2, $3 . $6, $4, $5, $raw)#gme;
    }
    if ($wantFinal) {
        @skip = spans($s);
        $s =~ s{^([ \t]*)((?:\@[\w.]+(?:\([^)\n]*\))?\s+)*(?:(?:public|private|fileprivate|internal|nonisolated|indirect)\s+)*)(class)\s+(?!$modifier)(\w+)}{ (inside($-[3]) || $subclassed{$4}) ? $& : "$1$2final " . substr($&, length($1) + length($2)) }gme;
    }
    open(my $out, '>', $file) or die "$file: $!"; print $out $s; close($out);
}
LAMPLIVE
  # The names something may subclass, so every other class can be final.
  SUBCLASSED=$(perl "$LIVE/live.pl" scan -own=LampSupport.swift,LampScene.swift -bytes="$LIVE/byte-structs" Sources/**/*.swift(N) 2>/dev/null || true)
  # The pass is kept for each file with what it was made from, and taken again only when any of that changed:
  # over LampSupport.swift, which hardly ever does, it takes a second or more, and every change waited for it.
  KEY="4|$(cksum < "$LIVE/live.pl")|$SUBCLASSED"
  for f in Sources/**/*.swift(N); do
    out="$LIVE/$f"
    made="$LIVE/.made/$f"
    mkdir -p "${out:h}" "${made:h}"
    # Lamp's own files get the body wrap and the entry only; the app's get spare places and final classes too,
    # unless either kept the app from building.
    flags=""
    case "${f:t}" in LampSupport.swift|LampScene.swift) ;; *) [[ -e "$LIVE/no-spares" ]] || flags="${flags}s"; [[ -e "$LIVE/no-final" ]] || flags="${flags}f" ;; esac
    if [[ -f "$made.out" ]] && cmp -s "$f" "$made.in" && [[ "$(cat "$made.key" 2>/dev/null)" == "$KEY|$flags" ]]; then
      cmp -s "$made.out" "$out" || cp "$made.out" "$out"
      continue
    fi
    # The entry is void until it's whole again, and holds the very text the pass was made from: the agent may
    # edit the file meanwhile, and a build ended halfway (a newer change's) must leave no entry that looks right.
    rm -f "$made.key"
    cp "$f" "$made.in"
    cp "$made.in" "$out.new"
    perl "$LIVE/live.pl" 4 "$SUBCLASSED" "$flags" "$out.new"
    cp "$out.new" "$made.out"; print -r -- "$KEY|$flags" > "$made.key"
    if cmp -s "$out.new" "$out"; then rm "$out.new"; else mv "$out.new" "$out"; fi
  done
  # Lamp's own file beside the spares (LiveSlots.addMemberwise) has no original to be kept by.
  for f in "$LIVE"/Sources/**/*.swift(N); do [[ -f "${f#$LIVE/}" || "${f:t}" == LampMemberwise.swift ]] || rm "$f"; done
  # What's built beside the app (a widget, a share extension) is built from the copy too, as it is.
  for d in Widget Share; do
    if [[ -d "$d" ]]; then mkdir -p "$LIVE/$d"; rsync -a --delete "$d/" "$LIVE/$d/"; else rm -rf "$LIVE/$d"; fi
  done
  # The widget's code the app shares, linked into Sources as it is there (WidgetShared), onto the copy.
  if [[ -L Sources/WidgetShared ]]; then ln -sfn ../Widget/Shared "$LIVE/Sources/WidgetShared"; elif [[ -L "$LIVE/Sources/WidgetShared" ]]; then rm "$LIVE/Sources/WidgetShared"; fi
  cmp -s Package.swift "$LIVE/Package.swift" || cp Package.swift "$LIVE/Package.swift"
  # Lamp only wants the live copy, to put a change into the open app before building the whole of it.
  [[ "${LAMP_LIVE_COPY:-}" == 1 ]] && exit 0
  # What this build compiles, which is what the app runs once it's installed (LiveReload.markRunning): kept
  # aside, and the record only once the build has worked, or a failed one would name code no app runs.
  rsync -a --delete "$LIVE/Sources/" "$LIVE/compiling/"
  FLAGS=(-c debug --package-path "$LIVE" --scratch-path "$LIVE/.build" -Xswiftc -DLAMP_LIVE -Xswiftc -enable-testing -Xlinker -interposable "${RESTRICT[@]}")
fi
# App Intents (Shortcuts, Siri, Spotlight, a widget's buttons): Xcode's tools write what the code declares into the app.
# What they did is kept in .build/appintents for this build alone: Lamp reads there whether they ran.
INTENTS=""
rm -rf .build/appintents
if grep -rqs --include='*.swift' -e 'import AppIntents' Sources Widget; then
  if PROCESSOR="$(xcrun -f appintentsmetadataprocessor 2>/dev/null)"; then
    INTENTS=1
    mkdir -p .build
    echo '["AnyResolverProviding","AppEntity","AppEnum","AppExtension","AppIntent","AppIntentsPackage","AppShortcutProviding","AppShortcutsProvider","AppUnionValue","AppUnionValueCasesProviding","DynamicOptionsProvider","EntityQuery","ExtensionPointDefining","IntentValueQuery","Resolver","TransientEntity","_AssistantIntentsProvider","_GenerativeFunctionExtractable","_IntentValueRepresentable"]' > .build/appintents-protocols.json
    # The compiler's own option for the protocols' list, named as this compiler names it: Swift 6.2 (Xcode 26.0)
    # knows only `-const-gather-protocols-file`, and only in the frontend.
    GATHER=-const-gather-protocols-list
    swiftc -frontend -help-hidden 2>/dev/null | grep -q -- "$GATHER" || GATHER=-const-gather-protocols-file
    FLAGS+=(-Xswiftc -emit-const-values -Xswiftc -Xfrontend -Xswiftc "$GATHER"
            -Xswiftc -Xfrontend -Xswiftc "$PWD/.build/appintents-protocols.json")
  else
    echo "warning: Xcode isn't installed, so Siri, Shortcuts and Spotlight won't see this app's App Intents." >&2
  fi
fi
intents() {   # a program, its bundle, the bundle's id, the folder of its code
  [[ -n "$INTENTS" ]] || return 0
  local target="$1" bundle="$PWD/$2" id="$3" code="$4"
  local bindir="$(swift build "${FLAGS[@]}" --show-bin-path)"
  local work="$PWD/.build/appintents/$target"
  local toolchain="$(dirname "$(dirname "$(dirname "$PROCESSOR")")")"
  rm -rf "$work"
  mkdir -p "$work/ssu" "$bundle/Contents/Resources"
  : > "$work/none.txt"
  find "$(dirname "$(dirname "$bindir")")/Intermediates.noindex/DiskMap.build/$(basename "$bindir")/$target-p.build" \
    -name '*.swiftconstvalues' > "$work/constvalues.txt" 2>/dev/null || true
  if [[ ! -s "$work/constvalues.txt" ]]; then
    echo "warning: $target's App Intents weren't added: this Swift keeps the compiler's record where Lamp doesn't look." >&2
    return 0
  fi
  find -L "$PWD/$code" -name '*.swift' > "$work/sources.txt"
  if ! "$PROCESSOR" --toolchain-dir "$toolchain" --module-name "$target" --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" \
      --xcode-version "$(plutil -extract ProductBuildVersion raw "$toolchain/../../../version.plist" 2>/dev/null || echo 0)" \
      --platform-family macOS --deployment-target 14.0 --target-triple "$(uname -m)-apple-macos14.0" \
      --bundle-identifier "$id" --output "$bundle/Contents/Resources" --binary-file "$bundle/Contents/MacOS/$target" \
      --source-file-list "$work/sources.txt" --swift-const-vals-list "$work/constvalues.txt" \
      --metadata-file-list "$work/none.txt" --static-metadata-file-list "$work/none.txt" \
      --compile-time-extraction --deployment-aware-processing --no-app-shortcuts-localization > "$work/log.txt" 2>&1; then
    grep -iE "error|warning" "$work/log.txt" >&2 || cat "$work/log.txt" >&2
    echo "error: $target's App Intents couldn't be read." >&2
    return 1
  fi
  "$(dirname "$PROCESSOR")/appintentsnltrainingprocessor" --infoplist-path "$bundle/Contents/Info.plist" --source-file "$bundle/Contents/Info.plist" \
    --temp-dir-path "$work/ssu" --bundle-id "$id" --product-path "$bundle/Contents/Resources" \
    --extracted-metadata-path "$bundle/Contents/Resources/Metadata.appintents" --metadata-file-list "$work/none.txt" \
    --archive-ssu-assets >> "$work/log.txt" 2>&1 || echo "warning: Siri wasn't taught $target's phrases; Shortcuts still has them." >&2
}
BIN="$(swift build "${FLAGS[@]}" --show-bin-path)/DiskMap"
# SwiftPM doesn't relink for the new flags alone: an app first built by a Lamp without them keeps its old
# binary until the link runs again. Take that binary away once, and it links again with the segment.
if [ -f "$BIN" ] && ! otool -l "$BIN" 2>/dev/null | grep -qs __RESTRICT; then rm -f "$BIN"; fi
swift build "${FLAGS[@]}" 2>&1
if [[ "${LAMP_LIVE:-}" == 1 ]]; then rsync -a --delete "$LIVE/compiling/" "$LIVE/built/"; fi
APP="build/DiskMap.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/DiskMap"
# SwiftPM records the oldest macOS the app runs on as the SDK it was built with, and macOS draws an app the way
# the SDK it names did: Liquid Glass only for one built with macOS 26's or later. So the copy names the SDK it
# was really built with, the oldest macOS staying as it is.
if SDKVER="$(xcrun --sdk "${SDKROOT:-macosx}" --show-sdk-version 2>/dev/null)"   && MINOS="$(otool -l "$APP/Contents/MacOS/DiskMap" | awk '/minos/ {print $2; exit}')" && [ -n "$MINOS" ]; then
  xcrun vtool -set-build-version macos "$MINOS" "$SDKVER" -replace -output "$APP/Contents/MacOS/DiskMap" "$APP/Contents/MacOS/DiskMap" >/dev/null 2>&1 || true
fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>DiskMap</string>
  <key>CFBundleIdentifier</key><string>dev.lamp.dev.app.diskmap</string>
  <key>CFBundleName</key><string>${LAMP_APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>${LAMP_APP_NAME}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
${LAMP_MAC_USAGE}
</dict></plist>
PLIST
intents DiskMap "$APP" "dev.lamp.dev.app.diskmap" Sources
codesign --force -s - "$APP"
echo "Built $APP"
