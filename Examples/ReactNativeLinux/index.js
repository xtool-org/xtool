import React, {useState} from 'react';
import {AppRegistry, Pressable, SafeAreaView, StyleSheet, Text, View, useColorScheme} from 'react-native';

function LinuxDemo() {
  const [count, setCount] = useState(0);
  const dark = useColorScheme() === 'dark';
  const foreground = {color: dark ? '#f8fafc' : '#142038'};
  return (
    <SafeAreaView style={[styles.screen, {backgroundColor: dark ? '#101827' : '#f1f5fb'}]}>
      <View style={styles.content}>
        <Text style={styles.eyebrow}>REACT NATIVE · BUILT ON LINUX</Text>
        <Text style={[styles.title, foreground]}>Hello from{`\n`}Omarchy.</Text>
        <Text style={[styles.description, {color: dark ? '#b6c3d9' : '#53647f'}]}>
          This screen is rendered by React Native from JavaScript on your iPhone.
        </Text>
        <View style={[styles.card, {backgroundColor: dark ? '#1b2940' : '#ffffff'}]}>
          <Text style={[styles.counter, foreground]} accessibilityLabel={`Counter: ${count}`}>{count}</Text>
          <Text style={[styles.caption, {color: dark ? '#b6c3d9' : '#53647f'}]}>Tap to test React state</Text>
          <Pressable accessibilityRole="button" onPress={() => {
            setCount(value => value + 1);
            console.log(`[OmarchyRN] counter=${count + 1}`);
          }} style={({pressed}) => [styles.button, pressed && {opacity: 0.75}]}>
            <Text style={styles.buttonText}>Add one</Text>
          </Pressable>
        </View>
        <Text style={[styles.footer, {color: dark ? '#93a5bf' : '#657790'}]}>React Native 0.77.3 · JavaScriptCore</Text>
      </View>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  screen: {flex: 1}, content: {flex: 1, justifyContent: 'center', padding: 28},
  eyebrow: {color: '#687cf1', fontSize: 11, fontWeight: '700', letterSpacing: 1.4, marginBottom: 20},
  title: {fontSize: 46, fontWeight: '800', letterSpacing: -1.8, lineHeight: 51},
  description: {fontSize: 17, lineHeight: 25, marginTop: 18, marginBottom: 30},
  card: {borderRadius: 24, padding: 24, alignItems: 'center'},
  counter: {fontSize: 64, fontWeight: '700', fontVariant: ['tabular-nums']},
  caption: {fontSize: 14, marginTop: 4, marginBottom: 24},
  button: {backgroundColor: '#495dda', borderRadius: 14, paddingVertical: 16, alignSelf: 'stretch', alignItems: 'center'},
  buttonText: {color: '#ffffff', fontSize: 17, fontWeight: '700'},
  footer: {fontSize: 12, textAlign: 'center', marginTop: 25},
});

console.log('[OmarchyRN] registering React Native JavaScript screen');
AppRegistry.registerComponent('OmarchyReactNative', () => LinuxDemo);
