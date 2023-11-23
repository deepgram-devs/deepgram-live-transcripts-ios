//
//  ViewController.swift
//  deepgramstream
//
//  Created by Abdulhakim Ajetunmobi on 30/10/2021.
//

import UIKit
import AVFoundation
import Starscream
import OpenAI
let openAI = OpenAI(apiToken: "OPENAI_API_KEY")


class ViewController: UIViewController, AVAudioPlayerDelegate {
    var audioPlayer: AVAudioPlayer?
    private let apiKey = "DEEPGRAM_API_KEY"
    private let stt_url = "wss://api.deepgram.com/v1/listen?encoding=linear16&sample_rate=48000&channels=1&model=nova&smart_format=true&no_delay=true&endpointing=100";
    private let tts_url = "https://api.beta.deepgram.com/v1/speak";
    private let audioEngine = AVAudioEngine()
    private var speaking = false
    
    private lazy var socket: WebSocket = {
        let url = URL(string: stt_url)!
        var urlRequest = URLRequest(url: url)
        urlRequest.setValue("Token " + apiKey, forHTTPHeaderField: "Authorization")
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
        sendMicStream()
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
    
    private func sendMicStream() {
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
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            guard let channelData = buffer.floatChannelData else { return }

            let channelDataValue = channelData.pointee
            let channelDataValueArray = stride(from: 0,
                                               to: Int(buffer.frameLength),
                                               by: buffer.stride).map { channelDataValue[$0] }

            let rms = sqrt(channelDataValueArray.map { $0 * $0 }.reduce(0, +) / Float(buffer.frameLength))

            let avgPower = 20 * log10(rms)
            print("Average Power in dB: \(avgPower)")
            // TODO VAD
//            if avgPower > -40 {
//                self.audioPlayer?.pause()
//            }
        }
        
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
            print("jsonData")
            print(jsonData)
            let response = try! jsonDecoder.decode(DeepgramResponse.self, from: jsonData)
            if response.channel != nil {
                let transcript = response.channel.alternatives.first!.transcript
                if transcript.count > 0 {
                    
                    if (!speaking){
                        
                        if response.isFinal && !transcript.isEmpty {
                            if transcriptView.text.isEmpty {
                                transcriptView.text = transcript
                            } else {
                                transcriptView.text = transcriptView.text + "\n" + transcript
                            }
                            
                            //                        self.audioPlayer?.pause()
                        }
                        
                        let systemPrompt = "You are a firendly assistant. Respond with short responses in a conversation like fashion. DO NOT respond with more than 2 sentences and try to use short responses where possible. "
                        
                        let query = CompletionsQuery(model: .textDavinci_003, prompt: systemPrompt + " " + transcript, temperature: 0, maxTokens: 100, topP: 1, frequencyPenalty: 0, presencePenalty: 0, stop: ["\\n"])
                        openAI.completions(query: query) { result in
                            //Handle result here
                            switch result {
                            case .success(let result):
                                print("=========")
                                print(result.choices[0].text)
                                self.downloadAndPlayAudio(text: result.choices[0].text)
                                DispatchQueue.main.async() {
                                    self.transcriptView.text = self.transcriptView.text + "\n" + result.choices[0].text + "\n"
                                }
                            case .failure(let error):
                                //Handle chunk error here
                                
                                print("=== Error ======")
                                print(error)
                            }
                        }
                    }
                }
            }
        
            
        case .error(let error):
            print(error ?? "")
        default:
            break
        }
    }
    
    func downloadAndPlayAudio(text: String) {
        let url = URL(string: tts_url)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let parameters: [String: Any] = [
            "text": text
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: parameters)

        // Headers
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("token " + apiKey , forHTTPHeaderField: "Authorization")
        
        let session = URLSession.shared
        let downloadTask = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            if let error = error {
                print("Error downloading audio: \(error)")
                return
            }

            guard let data = data, error == nil else {
                print("No data or there is an error")
                return
            }

            // Playing the audio on the main thread
            DispatchQueue.main.async {
                do {
                    do {
//                        audioSession.setActive(false)
                        try AVAudioSession.sharedInstance().setCategory(.playAndRecord, options: [.defaultToSpeaker])
//                        audioSession.setActive(true)
                    } catch let error {
                        print(error.localizedDescription)
                    }
                    self.audioPlayer = try AVAudioPlayer(data: data)
                    self.audioPlayer?.setVolume(40, fadeDuration: 0)
                    self.audioPlayer?.prepareToPlay()
                    self.audioPlayer?.delegate = self
                    self.audioPlayer?.play()
                    self.speaking = true
                    
                    // timer based listening
//                    let timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { timer in
//                        print("Time is Over")
//                        self.speaking = false
//                    }
                    
                    Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                        let decibels = self.getDecibels()
                        print("Current out decibels: \(decibels)")
                    }
                } catch {
                    print("Error playing audio: \(error)")
                }
            }
        }
        downloadTask.resume()
    }
    
    private func getDecibels() -> Float {
        self.audioPlayer?.updateMeters()
        return self.audioPlayer?.averagePower(forChannel: 0) ?? 0.0
    }
    
    private func getAudioStream(text: String) {
        print("TTS: ")
        print(text)
        let url = URL(string: tts_url)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        // Set the request body
        let postData = PostData(text: text)
        let jsonData = try! JSONEncoder().encode(postData)

        request.httpBody = jsonData

        // Headers
        request.addValue("application/json", forHTTPHeaderField: "content-type")
        request.addValue("Authorization", forHTTPHeaderField: "token " + apiKey)

        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data else {
                print("Error: ")
                print(error!)
                return
            }

            print(String(data: data, encoding: .utf8)!)
            
            do {
                let player = try AVAudioPlayer(data: data)
                player.play()
            } catch {
                print("Unable to play audio", error)
            }
        }

        task.resume()
    }
    
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        print("audioPlayerDidFinishPlaying")
    }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        print("audioPlayerDecodeErrorDidOccur")
    }
    func audioPlayerBeginInterruption(_ player: AVAudioPlayer) {
        print("audioPlayerBeginInterruption")
    }
    func audioPlayerEndInterruption(_ player: AVAudioPlayer, withOptions flags: Int) {
        print("audioPlayerEndInterruption")
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

struct PostData: Codable {
    let text: String
}
