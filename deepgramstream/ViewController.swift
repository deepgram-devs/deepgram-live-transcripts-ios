//
//  ViewController.swift
//  deepgramstream
//
//  Created by Abdulhakim Ajetunmobi on 30/10/2021.
//

import UIKit
import AVFoundation
import Starscream

class ViewController: UIViewController {
    
    private let apiKey = "Token YOUR_DEEPGRAM_API_KEY"
    private let audioEngine = AVAudioEngine()
    
    private lazy var socket: WebSocket = {
        let url = URL(string: "wss://api.deepgram.com/v1/listen?encoding=linear16&sample_rate=48000&channels=1&model=nova&smart_format=true&filler_words=true")!
        var urlRequest = URLRequest(url: url)
        urlRequest.setValue(apiKey, forHTTPHeaderField: "Authorization")
        return WebSocket(request: urlRequest)
    }()
    
    private let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
    
    private let transcriptView: UITextView = {
        let textView = UITextView()
        textView.isScrollEnabled = true
        textView.backgroundColor = .systemBackground
        textView.textColor = .label // Use the system label color (light mode/dark mode)
        textView.font = UIFont.systemFont(ofSize: 24, weight: .regular) // Use a larger, readable font
        textView.translatesAutoresizingMaskIntoConstraints = false
        return textView
    }()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        socket.delegate = self
        socket.connect()
        setupView()
        startAnalyzingAudio()
    }
    
    private func setupView() {
        view.addSubview(transcriptView)
        NSLayoutConstraint.activate([
            transcriptView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 40),
            transcriptView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            transcriptView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            transcriptView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -40)
        ])
    }
    
    private func startAnalyzingAudio() {
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: inputFormat.sampleRate, channels: inputFormat.channelCount, interleaved: true)
        let converterNode = AVAudioMixerNode()
        let sinkNode = AVAudioMixerNode()
        
        audioEngine.attach(converterNode)
        audioEngine.attach(sinkNode)
        
        converterNode.installTap(onBus: 0, bufferSize: 1024, format: converterNode.outputFormat(forBus: 0)) { (buffer: AVAudioPCMBuffer!, time: AVAudioTime!) -> Void in
            if let data = self.toNSData(buffer: buffer) {
                self.socket.write(data: data)
            }
        }
        
        audioEngine.connect(inputNode, to: converterNode, format: inputFormat)
        audioEngine.connect(converterNode, to: sinkNode, format: outputFormat)
        audioEngine.prepare()
        
        do {
            try AVAudioSession.sharedInstance().setCategory(.record)
            try audioEngine.start()
        } catch {
            print(error)
        }
    }
    
    private func toNSData(buffer: AVAudioPCMBuffer) -> Data? {
        let audioBuffer = buffer.audioBufferList.pointee.mBuffers
        return Data(bytes: audioBuffer.mData!, count: Int(audioBuffer.mDataByteSize))
    }
}

extension ViewController: WebSocketDelegate {
    func didReceive(event: WebSocketEvent, client: WebSocket) {
        switch event {
        case .text(let text):
            let jsonData = Data(text.utf8)
            let response = try! jsonDecoder.decode(DeepgramResponse.self, from: jsonData)
            let transcript = response.channel.alternatives.first!.transcript
        
            if response.isFinal && !transcript.isEmpty {
                if transcriptView.text.isEmpty {
                    transcriptView.text = transcript
                } else {
                    transcriptView.text = transcriptView.text + " " + transcript
                }
            }
        case .error(let error):
            print(error ?? "")
        default:
            break
        }
    }
}

struct DeepgramResponse: Codable {
    let isFinal: Bool
    let channel: Channel
    
    struct Channel: Codable {
        let alternatives: [Alternatives]
    }
    
    struct Alternatives: Codable {
        let transcript: String
    }
}
