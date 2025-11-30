class ReferenceItem {
  final String title;
  final String url;
  final String snippet;
  final String sourceName;
  // Optional: image identifier for vision results
  final String? imageId;
  // Optional category/type: 'web' | 'vision' | 'image' | 'other'
  final String sourceType;

  ReferenceItem({
    required this.title,
    required this.url,
    required this.snippet,
    required this.sourceName,
    this.imageId,
    this.sourceType = 'web',
  });

  Map<String, dynamic> toJson() => {
        'title': title,
        'url': url,
        'snippet': snippet,
        'sourceName': sourceName,
        'imageId': imageId,
        'sourceType': sourceType,
      };

  factory ReferenceItem.fromJson(Map<String, dynamic> json) {
    return ReferenceItem(
      title: json['title'] ?? '',
      url: json['url'] ?? '',
      snippet: json['snippet'] ?? '',
      sourceName: json['sourceName'] ?? '',
      imageId: json['imageId'],
      sourceType: json['sourceType'] ?? 'web',
    );
  }
}
