## Button
```swift
            Button(action: {
                isARActive.toggle()
            }) {
                Text(isARActive ? "关闭AR" : "打开AR")
                    .foregroundColor(.white)
                    .padding()
                    .background(Color.blue)
                    .cornerRadius(10)
            }
            .position(x: UIScreen.main.bounds.width/2, y: UIScreen.main.bounds.height - 100)
```

